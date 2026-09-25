-- ============================================================================
-- La « salle durable » — tickets T10 + T11 de docs/PLAN_ONLINE_V2.md
-- ----------------------------------------------------------------------------
-- La vérité d'une partie Online ne vit plus dans la RAM de l'hôte mais dans une
-- ligne `online_rooms` versionnée. L'hôte *anime* (tempo des reveals) et écrit
-- en CAS (`room_publish(expected_version)`) ; les guests lisent (`room_get`,
-- mains expurgées) et écrivent seulement leurs annonces (`room_submit`).
-- Un bail (`host_lease_until`, 15 s) rend la relève d'hôte déterministe.
--
-- Format du JSON stocké dans `state` : encodage `Codable` de `OnlineRoom`
-- (clés camelCase). ATTENTION — vérifié empiriquement avec Swift 6.4 :
-- un `[Int: T]` Swift est encodé par JSONEncoder comme un **objet** dont les
-- clés sont les entiers en texte (`{"0": [...], "2": [...]}`), PAS comme un
-- tableau alterné. Les helpers ci-dessous manipulent donc des objets jsonb.
-- Autre piège vérifié : `UUID` est encodé en MAJUSCULES par Swift
-- (`"10569577-513E-..."`) alors que `auth.uid()::text` est en minuscules ;
-- toutes les comparaisons passent donc par un cast `::uuid` (insensible à la
-- casse), jamais par une égalité de texte.
--
-- Toutes les erreurs sont levées en `MAJUSCULES_SNAKE` avec errcode P0001 :
-- le client Swift matche le `message`.
-- ============================================================================

-- ============================================================================
-- 1. Tables
-- ============================================================================

-- Une ligne par salon. `state` = OnlineRoom encodé, `version` = compteur CAS.
create table if not exists public.online_rooms (
  code             text primary key,                    -- 4 chars (alphabet lisible)
  host_user_id     uuid not null references auth.users(id) on delete cascade,
  host_lease_until timestamptz not null default now() + interval '15 seconds',
  version          bigint not null default 1,
  status           text not null default 'lobby' check (status in ('lobby','playing','finished')),
  state            jsonb not null,                      -- OnlineRoom encodé (sans champs dérivés)
  cloud_game_id    uuid references public.games(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.online_rooms is
  'Salle durable Online : état versionné d''une partie (source de vérité, plus la RAM de l''hôte).';

-- Une ligne par membre (même parti : `left_at` non nul, on garde la trace).
create table if not exists public.online_room_members (
  code         text not null references public.online_rooms(code) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  seat_hint    int,
  joined_at    timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  left_at      timestamptz,
  primary key (code, user_id)
);

comment on table public.online_room_members is
  'Membres d''un salon Online. `last_seen_at` alimente la grâce de présence (T23).';

create index if not exists online_rooms_updated_idx
  on public.online_rooms(updated_at desc);

create index if not exists online_room_members_user_idx
  on public.online_room_members(user_id);

-- `updated_at` automatique (fonction déjà définie par 20260513054433_init_profiles).
drop trigger if exists online_rooms_touch_updated_at on public.online_rooms;
create trigger online_rooms_touch_updated_at
  before update on public.online_rooms
  for each row execute function public.touch_updated_at();

-- Realtime : le client n'écoute que les UPDATE (simple *ping* → il relit via
-- room_get). `replica identity full` est inutile.
do $pub$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'online_rooms'
  ) then
    alter publication supabase_realtime add table public.online_rooms;
  end if;
exception when others then
  raise notice 'publication supabase_realtime indisponible (%)', sqlerrm;
end
$pub$;

-- ============================================================================
-- 2. Helpers jsonb (privés — jamais exposés à `authenticated`)
-- ============================================================================

-- Horodatage stable pour le client Swift : ISO-8601 UTC avec millisecondes.
create or replace function public._room_ts(p_ts timestamptz)
returns text
language sql
stable
as $$
  select to_char(p_ts at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;

-- Seat du joueur `p_user` dans `state.gameState.players`, ou null s'il n'y joue pas.
create or replace function public._room_seat_of(p_state jsonb, p_user uuid)
returns int
language sql
stable
set search_path = public, pg_temp
as $$
  select (p->>'seat')::int
  from jsonb_array_elements(coalesce(p_state->'gameState'->'players', '[]'::jsonb)) as p
  where nullif(p->>'userId','') is not null
    and (p->>'userId')::uuid = p_user
  limit 1;
$$;

-- Index (dans le tableau `players`) du siège `p_seat`, ou null.
create or replace function public._room_player_index(p_state jsonb, p_seat int)
returns int
language sql
stable
set search_path = public, pg_temp
as $$
  select (t.ord - 1)::int
  from jsonb_array_elements(coalesce(p_state->'gameState'->'players', '[]'::jsonb))
       with ordinality as t(p, ord)
  where (t.p->>'seat')::int = p_seat
  limit 1;
$$;

-- Main d'un siège : `state.gameState.hands["<seat>"]`, `[]` si absente.
-- (`hands` est un OBJET jsonb — cf. en-tête du fichier.)
create or replace function public._room_hands_get(p_state jsonb, p_seat int)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(p_state->'gameState'->'hands'->(p_seat::text), '[]'::jsonb);
$$;

-- `state` expurgé pour un appelant qui n'est pas l'hôte : `gameState.hands`
-- réduit à la main de `p_seat` (vide si null), et toutes les cartes que seul
-- l'hôte a le droit de connaître à l'avance remises à `[]` (`pendingFlop`,
-- `pendingTurns`, `pendingRivers`, `burns`). Les guests n'ont besoin que de
-- `communityCards` (déjà révélées) et de `burnsRevealed` (un simple compteur).
create or replace function public._room_state_redact(p_state jsonb, p_seat int)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_out   jsonb := p_state;
  v_gs    jsonb := p_state->'gameState';
  v_hands jsonb;
  v_kept  jsonb := '{}'::jsonb;
  v_key   text;
begin
  if v_gs is null or jsonb_typeof(v_gs) <> 'object' then
    return p_state;
  end if;

  v_hands := v_gs->'hands';
  if v_hands is not null and jsonb_typeof(v_hands) = 'object' then
    if p_seat is not null and jsonb_exists(v_hands, p_seat::text) then
      v_kept := jsonb_build_object(p_seat::text, v_hands->(p_seat::text));
    end if;
    v_out := jsonb_set(v_out, '{gameState,hands}', v_kept, true);
  end if;

  foreach v_key in array array['pendingFlop','pendingTurns','pendingRivers','burns'] loop
    if jsonb_exists(v_gs, v_key) then
      v_out := jsonb_set(v_out, array['gameState', v_key], '[]'::jsonb, true);
    end if;
  end loop;

  return v_out;
end;
$$;

-- Écrit une annonce dans `gameState.submissions` (ou dans le dernier
-- `gameState.tiebreakBoards[].submissions` si `p_tiebreak`). Crée les parents
-- manquants pour rester tolérant à un state ancien.
create or replace function public._room_submissions_set(
  p_state      jsonb,
  p_seat       int,
  p_submission jsonb,
  p_tiebreak   boolean
)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_out jsonb := p_state;
  v_idx int;
  v_sub jsonb;
begin
  if p_tiebreak then
    v_idx := jsonb_array_length(coalesce(p_state->'gameState'->'tiebreakBoards', '[]'::jsonb)) - 1;
    if v_idx < 0 then
      return p_state;
    end if;
    v_sub := coalesce(p_state->'gameState'->'tiebreakBoards'->v_idx->'submissions', '{}'::jsonb);
    v_sub := jsonb_set(v_sub, array[p_seat::text], p_submission, true);
    v_out := jsonb_set(v_out,
                       array['gameState','tiebreakBoards', v_idx::text, 'submissions'],
                       v_sub, true);
  else
    v_sub := coalesce(p_state->'gameState'->'submissions', '{}'::jsonb);
    v_sub := jsonb_set(v_sub, array[p_seat::text], p_submission, true);
    v_out := jsonb_set(v_out, '{gameState,submissions}', v_sub, true);
  end if;
  return v_out;
end;
$$;

-- Fusion d'un objet d'annonces : tout ce qui est en base et absent du payload
-- est réinjecté (l'hôte ne peut jamais effacer l'annonce d'un guest).
create or replace function public._room_merge_sub_objects(p_db jsonb, p_new jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_out jsonb := coalesce(p_new, '{}'::jsonb);
  v_db  jsonb := coalesce(p_db,  '{}'::jsonb);
  k     text;
begin
  if jsonb_typeof(v_db) <> 'object' then return v_out; end if;
  if jsonb_typeof(v_out) <> 'object' then v_out := '{}'::jsonb; end if;
  for k in select jsonb_object_keys(v_db) loop
    if not jsonb_exists(v_out, k) then
      v_out := jsonb_set(v_out, array[k], v_db->k, true);
    end if;
  end loop;
  return v_out;
end;
$$;

-- Fusion des annonces entre l'état en base et le payload de l'hôte, pour le
-- board courant ET le dernier tie-break. Garde-fou : on ne fusionne que si le
-- payload parle du MÊME tour d'annonce (manche/board/rebid identiques et phase
-- encore annonçante), sinon on ressusciterait des annonces d'un board précédent.
create or replace function public._room_merge_submissions(p_db_state jsonb, p_new_state jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_out     jsonb := p_new_state;
  v_db_gs   jsonb := p_db_state->'gameState';
  v_new_gs  jsonb := p_new_state->'gameState';
  v_db_tb   jsonb;
  v_new_tb  jsonb;
  v_idx     int;
  v_db_last jsonb;
  v_nw_last jsonb;
begin
  if v_db_gs is null or v_new_gs is null
     or jsonb_typeof(v_db_gs) <> 'object' or jsonb_typeof(v_new_gs) <> 'object' then
    return p_new_state;
  end if;

  -- Même tour d'annonce ?
  if (v_db_gs->>'mancheNumber') is distinct from (v_new_gs->>'mancheNumber')
     or (v_db_gs->>'currentBoard') is distinct from (v_new_gs->>'currentBoard')
     or (v_db_gs->>'rebidRound')   is distinct from (v_new_gs->>'rebidRound')
     or coalesce(v_new_gs->>'phase','') not in ('announcing','tiebreakAnnouncing') then
    return p_new_state;
  end if;

  -- Board courant
  v_out := jsonb_set(
    v_out, '{gameState,submissions}',
    public._room_merge_sub_objects(v_db_gs->'submissions', v_new_gs->'submissions'),
    true);

  -- Dernier tie-break (même pile, même parent, même round)
  v_db_tb  := coalesce(v_db_gs->'tiebreakBoards',  '[]'::jsonb);
  v_new_tb := coalesce(v_out->'gameState'->'tiebreakBoards', '[]'::jsonb);
  if jsonb_array_length(v_db_tb) > 0
     and jsonb_array_length(v_db_tb) = jsonb_array_length(v_new_tb) then
    v_idx     := jsonb_array_length(v_new_tb) - 1;
    v_db_last := v_db_tb->v_idx;
    v_nw_last := v_new_tb->v_idx;
    if (v_db_last->>'parentBoardIdx') is not distinct from (v_nw_last->>'parentBoardIdx')
       and (v_db_last->>'round') is not distinct from (v_nw_last->>'round') then
      v_out := jsonb_set(
        v_out,
        array['gameState','tiebreakBoards', v_idx::text, 'submissions'],
        public._room_merge_sub_objects(v_db_last->'submissions', v_nw_last->'submissions'),
        true);
    end if;
  end if;

  return v_out;
end;
$$;

-- Membre non parti ? (version interne, sans SECURITY DEFINER)
create or replace function public._room_is_member(p_code text, p_user uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.online_room_members m
    where m.code = p_code and m.user_id = p_user and m.left_at is null
  );
$$;

-- Liste des membres d'un salon, pour les retours des RPC.
create or replace function public._room_members_json(p_code text)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',      m.user_id,
        'display_name', m.display_name,
        'last_seen_at', public._room_ts(m.last_seen_at),
        'left_at',      case when m.left_at is null then null else public._room_ts(m.left_at) end
      )
      order by m.joined_at, m.user_id
    ),
    '[]'::jsonb)
  from public.online_room_members m
  where m.code = p_code;
$$;

revoke all on function public._room_ts(timestamptz)                         from public, anon, authenticated;
revoke all on function public._room_seat_of(jsonb, uuid)                    from public, anon, authenticated;
revoke all on function public._room_player_index(jsonb, int)                from public, anon, authenticated;
revoke all on function public._room_hands_get(jsonb, int)                   from public, anon, authenticated;
revoke all on function public._room_state_redact(jsonb, int)                from public, anon, authenticated;
revoke all on function public._room_submissions_set(jsonb, int, jsonb, boolean) from public, anon, authenticated;
revoke all on function public._room_merge_sub_objects(jsonb, jsonb)         from public, anon, authenticated;
revoke all on function public._room_merge_submissions(jsonb, jsonb)         from public, anon, authenticated;
revoke all on function public._room_is_member(text, uuid)                   from public, anon, authenticated;
revoke all on function public._room_members_json(text)                      from public, anon, authenticated;

-- ============================================================================
-- 3. RLS — lecture seule, via un helper SECURITY DEFINER (leçon my_game_ids :
--    jamais de policies qui se référencent entre elles).
-- ============================================================================

-- Vrai si l'appelant est membre non parti du salon. Utilisé par les policies.
create or replace function public.is_room_member(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.online_room_members m
    where m.code = p_code
      and m.user_id = auth.uid()
      and m.left_at is null
  );
$$;

comment on function public.is_room_member(text) is
  'Vrai si auth.uid() est membre non parti du salon. SECURITY DEFINER pour éviter la récursion RLS.';

alter table public.online_rooms        enable row level security;
alter table public.online_room_members enable row level security;

drop policy if exists "online_rooms visible aux membres"        on public.online_rooms;
drop policy if exists "online_room_members visible aux membres" on public.online_room_members;

create policy "online_rooms visible aux membres"
  on public.online_rooms for select
  using (public.is_room_member(code));

create policy "online_room_members visible aux membres"
  on public.online_room_members for select
  using (public.is_room_member(code));

-- Aucune policy insert/update/delete : toutes les écritures passent par les RPC.
revoke all on table public.online_rooms        from anon;
revoke all on table public.online_rooms        from authenticated;
revoke all on table public.online_room_members from anon;
revoke all on table public.online_room_members from authenticated;
grant select on table public.online_rooms        to authenticated;
grant select on table public.online_room_members to authenticated;

revoke all on function public.is_room_member(text) from public, anon;
grant execute on function public.is_room_member(text) to authenticated;

-- ============================================================================
-- 4. RPC
-- ============================================================================

-- ---------------------------------------------------------------------------
-- room_get : la ligne du salon + les membres, avec `state` expurgé pour un
-- appelant qui n'est pas l'hôte : seule sa main dans `gameState.hands`, et
-- `pendingFlop` / `pendingTurns` / `pendingRivers` / `burns` vidés. En phase
-- `mancheEnd`, et pour l'hôte, tout est visible.
-- ---------------------------------------------------------------------------
create or replace function public.room_get(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_code  text := upper(trim(coalesce(p_code, '')));
  v_room  public.online_rooms%rowtype;
  v_state jsonb;
  v_seat  int;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;

  if not public._room_is_member(v_code, v_me) then
    raise exception using errcode = 'P0001', message = 'NOT_MEMBER';
  end if;

  if v_room.host_user_id = v_me
     or coalesce(v_room.state->'gameState'->>'phase', '') = 'mancheEnd' then
    v_state := v_room.state;
  else
    v_seat  := public._room_seat_of(v_room.state, v_me);
    v_state := public._room_state_redact(v_room.state, v_seat);
  end if;

  return jsonb_build_object(
    'code',             v_room.code,
    'version',          v_room.version,
    'status',           v_room.status,
    'host_user_id',     v_room.host_user_id,
    'host_lease_until', public._room_ts(v_room.host_lease_until),
    'server_now',       public._room_ts(now()),
    'cloud_game_id',    v_room.cloud_game_id,
    'state',            v_state,
    'members',          public._room_members_json(v_code)
  );
end;
$$;

comment on function public.room_get(text) is
  'Lit un salon : ligne + membres + state expurgé (main de l''appelant seule, cartes à venir vidées) sauf hôte ou phase mancheEnd.';

-- ---------------------------------------------------------------------------
-- room_create : crée le salon (code fourni ou tiré au sort), l'hôte comme
-- unique participant, et pose le bail à 15 s.
-- ---------------------------------------------------------------------------
create or replace function public.room_create(
  p_code         text  default null,
  p_display_name text  default null,
  p_state        jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       uuid := auth.uid();
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code     text;
  v_name     text;
  v_state    jsonb;
  v_status   text;
  v_cloud    uuid;
  v_existing public.online_rooms%rowtype;
  v_try      int;
  v_i        int;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception using errcode = 'P0001', message = 'BAD_STATE';
  end if;

  v_name := coalesce(nullif(trim(coalesce(p_display_name, '')), ''), 'Joueur');

  if p_code is not null and trim(p_code) <> '' then
    v_code := upper(trim(p_code));
    if v_code !~ '^[A-Z0-9]{3,8}$' then
      raise exception using errcode = 'P0001', message = 'BAD_CODE';
    end if;
    select * into v_existing from public.online_rooms r where r.code = v_code;
    if found then
      if v_existing.status in ('lobby','playing') and v_existing.host_user_id <> v_me then
        raise exception using errcode = 'P0001', message = 'CODE_TAKEN';
      end if;
      -- Même hôte (ou salon terminé) : on remplace (cascade sur les membres).
      delete from public.online_rooms r where r.code = v_code;
    end if;
  else
    -- Tirage aléatoire avec retry sur collision.
    v_try := 0;
    loop
      v_try := v_try + 1;
      v_code := '';
      for v_i in 1..4 loop
        v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
      end loop;
      exit when not exists (select 1 from public.online_rooms r where r.code = v_code);
      if v_try >= 50 then
        raise exception using errcode = 'P0001', message = 'CODE_EXHAUSTED';
      end if;
    end loop;
  end if;

  -- Le serveur impose l'identité du salon : code, hôte, liste des participants.
  v_state := p_state
    || jsonb_build_object(
         'code',        v_code,
         'hostUserId',  v_me::text,
         'participants', jsonb_build_array(
            jsonb_build_object(
              'userId',      v_me::text,
              'displayName', v_name,
              'isHost',      true,
              'isOnline',    true)));

  v_status := coalesce(nullif(v_state->>'status', ''), 'lobby');
  if v_status not in ('lobby','playing','finished') then
    v_status := 'lobby';
  end if;
  v_state := jsonb_set(v_state, '{status}', to_jsonb(v_status), true);

  -- cloud_game_id : seulement s'il pointe une `games` réelle (FK).
  v_cloud := null;
  begin
    v_cloud := nullif(v_state->>'cloudGameId', '')::uuid;
  exception when others then
    v_cloud := null;
  end;
  if v_cloud is not null and not exists (select 1 from public.games g where g.id = v_cloud) then
    v_cloud := null;
  end if;

  insert into public.online_rooms (code, host_user_id, host_lease_until, version, status, state, cloud_game_id)
  values (v_code, v_me, now() + interval '15 seconds', 1, v_status, v_state, v_cloud);

  insert into public.online_room_members (code, user_id, display_name)
  values (v_code, v_me, v_name)
  on conflict (code, user_id) do update
    set display_name = excluded.display_name,
        last_seen_at = now(),
        left_at      = null;

  return public.room_get(v_code);
end;
$$;

comment on function public.room_create(text, text, jsonb) is
  'Crée un salon (code fourni ou tiré au sort) avec l''appelant comme hôte et seul participant.';

-- ---------------------------------------------------------------------------
-- room_join : (ré)inscrit l'appelant comme membre et l'ajoute à
-- `state.participants` s'il en est absent.
-- ---------------------------------------------------------------------------
create or replace function public.room_join(p_code text, p_display_name text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     uuid := auth.uid();
  v_code   text := upper(trim(coalesce(p_code, '')));
  v_room   public.online_rooms%rowtype;
  v_name   text;
  v_state  jsonb;
  v_parts  jsonb;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  if v_room.status = 'finished' then
    raise exception using errcode = 'P0001', message = 'ROOM_FINISHED';
  end if;

  v_name := coalesce(nullif(trim(coalesce(p_display_name, '')), ''), 'Joueur');

  insert into public.online_room_members (code, user_id, display_name)
  values (v_code, v_me, v_name)
  on conflict (code, user_id) do update
    set display_name = excluded.display_name,
        last_seen_at = now(),
        left_at      = null;

  v_state := v_room.state;
  v_parts := coalesce(v_state->'participants', '[]'::jsonb);
  if not exists (
    select 1 from jsonb_array_elements(v_parts) as p
    where nullif(p->>'userId','') is not null and (p->>'userId')::uuid = v_me
  ) then
    v_parts := v_parts || jsonb_build_array(
      jsonb_build_object(
        'userId',      v_me::text,
        'displayName', v_name,
        'isHost',      false,
        'isOnline',    true));
    v_state := jsonb_set(v_state, '{participants}', v_parts, true);
  end if;

  update public.online_rooms r
     set state   = v_state,
         version = r.version + 1
   where r.code = v_code;

  return public.room_get(v_code);
end;
$$;

comment on function public.room_join(text, text) is
  'Rejoint un salon : upsert du membre + ajout dans state.participants si absent, version+1.';

-- ---------------------------------------------------------------------------
-- room_publish : écriture CAS de l'hôte. Conflit de version = aucune écriture.
-- Fusionne les annonces reçues entre-temps pour ne jamais les effacer.
-- ---------------------------------------------------------------------------
create or replace function public.room_publish(
  p_code             text,
  p_expected_version bigint,
  p_state            jsonb,
  p_status           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     uuid := auth.uid();
  v_code   text := upper(trim(coalesce(p_code, '')));
  v_room   public.online_rooms%rowtype;
  v_state  jsonb;
  v_status text;
  v_cloud  uuid;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception using errcode = 'P0001', message = 'BAD_STATE';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;

  -- Hôte ET bail encore valide (un ex-hôte qui revient se fait refuser ici).
  if v_room.host_user_id <> v_me or v_room.host_lease_until <= now() then
    raise exception using errcode = 'P0001', message = 'NOT_HOST';
  end if;

  if v_room.version <> p_expected_version then
    return jsonb_build_object('conflict', true, 'room', public.room_get(v_code));
  end if;

  v_status := coalesce(nullif(trim(coalesce(p_status, '')), ''), v_room.status);
  if v_status not in ('lobby','playing','finished') then
    raise exception using errcode = 'P0001', message = 'BAD_STATUS';
  end if;

  -- Fusion des annonces + identité du salon imposée par le serveur.
  v_state := public._room_merge_submissions(v_room.state, p_state);
  v_state := jsonb_set(v_state, '{code}',   to_jsonb(v_code),  true);
  v_state := jsonb_set(v_state, '{status}', to_jsonb(v_status), true);

  v_cloud := v_room.cloud_game_id;
  begin
    v_cloud := coalesce(nullif(v_state->>'cloudGameId', '')::uuid, v_room.cloud_game_id);
  exception when others then
    v_cloud := v_room.cloud_game_id;
  end;
  if v_cloud is not null and not exists (select 1 from public.games g where g.id = v_cloud) then
    v_cloud := v_room.cloud_game_id;
  end if;

  update public.online_rooms r
     set state            = v_state,
         status           = v_status,
         cloud_game_id    = v_cloud,
         version          = r.version + 1,
         host_lease_until = now() + interval '15 seconds'
   where r.code = v_code;

  update public.online_room_members m
     set last_seen_at = now()
   where m.code = v_code and m.user_id = v_me;

  return jsonb_build_object('conflict', false, 'room', public.room_get(v_code));
end;
$$;

comment on function public.room_publish(text, bigint, jsonb, text) is
  'Écriture CAS de l''hôte (expected_version) ; conflit = relecture sans écriture, annonces fusionnées.';

-- ---------------------------------------------------------------------------
-- room_submit : un joueur dépose son annonce pour son propre siège. Valide la
-- phase, la propriété du siège et l'appartenance des cartes à sa main.
-- ---------------------------------------------------------------------------
create or replace function public.room_submit(p_code text, p_seat int, p_submission jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       uuid := auth.uid();
  v_code     text := upper(trim(coalesce(p_code, '')));
  v_room     public.online_rooms%rowtype;
  v_phase    text;
  v_owner    uuid;
  v_tiebreak boolean;
  v_tb_idx   int;
  v_tb       jsonb;
  v_hand     jsonb;
  v_cat      text;
  v_state    jsonb;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;
  if p_submission is null or jsonb_typeof(p_submission) <> 'object'
     or nullif(p_submission->>'categoryId','') is null then
    raise exception using errcode = 'P0001', message = 'BAD_SUBMISSION';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  if not public._room_is_member(v_code, v_me) then
    raise exception using errcode = 'P0001', message = 'NOT_MEMBER';
  end if;

  v_phase := coalesce(v_room.state->'gameState'->>'phase', '');
  if v_phase not in ('announcing','tiebreakAnnouncing') then
    raise exception using errcode = 'P0001', message = 'BAD_PHASE';
  end if;
  v_tiebreak := (v_phase = 'tiebreakAnnouncing');

  -- Le siège doit appartenir à l'appelant.
  select nullif(p->>'userId','')::uuid into v_owner
  from jsonb_array_elements(coalesce(v_room.state->'gameState'->'players', '[]'::jsonb)) as p
  where (p->>'seat')::int = p_seat
  limit 1;
  if v_owner is null or v_owner <> v_me then
    raise exception using errcode = 'P0001', message = 'NOT_YOUR_SEAT';
  end if;

  if v_tiebreak then
    v_tb_idx := jsonb_array_length(coalesce(v_room.state->'gameState'->'tiebreakBoards', '[]'::jsonb)) - 1;
    if v_tb_idx < 0 then
      raise exception using errcode = 'P0001', message = 'BAD_PHASE';
    end if;
    v_tb := v_room.state->'gameState'->'tiebreakBoards'->v_tb_idx;
    if not (coalesce(v_tb->'eligibleSeats', '[]'::jsonb) @> to_jsonb(p_seat)) then
      raise exception using errcode = 'P0001', message = 'NOT_ELIGIBLE';
    end if;
    if jsonb_exists(coalesce(v_tb->'submissions', '{}'::jsonb), p_seat::text) then
      raise exception using errcode = 'P0001', message = 'ALREADY_SUBMITTED';
    end if;
  else
    if jsonb_exists(coalesce(v_room.state->'gameState'->'submissions', '{}'::jsonb), p_seat::text) then
      raise exception using errcode = 'P0001', message = 'ALREADY_SUBMITTED';
    end if;
  end if;

  -- Les cartes annoncées doivent venir de la main du siège ("skip" = aucune).
  v_cat  := p_submission->>'categoryId';
  v_hand := public._room_hands_get(v_room.state, p_seat);
  if v_cat <> 'skip' then
    if jsonb_typeof(coalesce(p_submission->'cards', '[]'::jsonb)) <> 'array' then
      raise exception using errcode = 'P0001', message = 'BAD_CARDS';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(coalesce(p_submission->'cards', '[]'::jsonb)) as c
      where not (v_hand @> jsonb_build_array(c))
    ) then
      raise exception using errcode = 'P0001', message = 'BAD_CARDS';
    end if;
  end if;

  v_state := public._room_submissions_set(v_room.state, p_seat, p_submission, v_tiebreak);

  update public.online_rooms r
     set state   = v_state,
         version = r.version + 1
   where r.code = v_code;

  update public.online_room_members m
     set last_seen_at = now()
   where m.code = v_code and m.user_id = v_me;

  return public.room_get(v_code);
end;
$$;

comment on function public.room_submit(text, int, jsonb) is
  'Dépose l''annonce d''un siège (board courant ou dernier tie-break) après validation phase/siège/cartes.';

-- ---------------------------------------------------------------------------
-- room_set_spectator : bascule `wantsToSpectate` du siège de l'appelant
-- (s'applique à la manche suivante, cf. OnlineGameState).
-- ---------------------------------------------------------------------------
create or replace function public.room_set_spectator(p_code text, p_seat int, p_wants boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_code  text := upper(trim(coalesce(p_code, '')));
  v_room  public.online_rooms%rowtype;
  v_owner uuid;
  v_idx   int;
  v_state jsonb;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  if not public._room_is_member(v_code, v_me) then
    raise exception using errcode = 'P0001', message = 'NOT_MEMBER';
  end if;

  select nullif(p->>'userId','')::uuid into v_owner
  from jsonb_array_elements(coalesce(v_room.state->'gameState'->'players', '[]'::jsonb)) as p
  where (p->>'seat')::int = p_seat
  limit 1;
  if v_owner is null or v_owner <> v_me then
    raise exception using errcode = 'P0001', message = 'NOT_YOUR_SEAT';
  end if;

  v_idx := public._room_player_index(v_room.state, p_seat);
  if v_idx is null then
    raise exception using errcode = 'P0001', message = 'NOT_YOUR_SEAT';
  end if;

  v_state := jsonb_set(v_room.state,
                       array['gameState','players', v_idx::text, 'wantsToSpectate'],
                       to_jsonb(coalesce(p_wants, false)), true);

  update public.online_rooms r
     set state   = v_state,
         version = r.version + 1
   where r.code = v_code;

  update public.online_room_members m
     set last_seen_at = now()
   where m.code = v_code and m.user_id = v_me;

  return public.room_get(v_code);
end;
$$;

comment on function public.room_set_spectator(text, int, boolean) is
  'Bascule wantsToSpectate sur le siège de l''appelant (appliqué à la manche suivante).';

-- ---------------------------------------------------------------------------
-- room_claim_host : prend le bail d'hôte si l'ancien a expiré (ou renouvelle
-- celui de l'hôte courant). Row lock = un seul gagnant.
-- ---------------------------------------------------------------------------
create or replace function public.room_claim_host(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_code  text := upper(trim(coalesce(p_code, '')));
  v_room  public.online_rooms%rowtype;
  v_state jsonb;
  v_parts jsonb;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  if not public._room_is_member(v_code, v_me) then
    raise exception using errcode = 'P0001', message = 'NOT_MEMBER';
  end if;

  if v_room.host_user_id <> v_me and v_room.host_lease_until > now() then
    raise exception using errcode = 'P0001', message = 'LEASE_ACTIVE';
  end if;

  v_state := jsonb_set(v_room.state, '{hostUserId}', to_jsonb(v_me::text), true);

  select coalesce(jsonb_agg(
           jsonb_set(t.p, '{isHost}',
                     to_jsonb(nullif(t.p->>'userId','') is not null
                              and (t.p->>'userId')::uuid = v_me),
                     true)
           order by t.ord), '[]'::jsonb)
    into v_parts
  from jsonb_array_elements(coalesce(v_state->'participants', '[]'::jsonb))
       with ordinality as t(p, ord);
  v_state := jsonb_set(v_state, '{participants}', v_parts, true);

  update public.online_rooms r
     set host_user_id     = v_me,
         host_lease_until = now() + interval '15 seconds',
         state            = v_state,
         version          = r.version + 1
   where r.code = v_code;

  update public.online_room_members m
     set last_seen_at = now()
   where m.code = v_code and m.user_id = v_me;

  return public.room_get(v_code);
end;
$$;

comment on function public.room_claim_host(text) is
  'Réclame le bail d''hôte (bail expiré, ou renouvellement par l''hôte courant) ; sinon LEASE_ACTIVE.';

-- ---------------------------------------------------------------------------
-- room_heartbeat : « je suis là ». Retour léger (sert de poll) : version,
-- hôte, bail, heure serveur, membres. N'écrit dans online_rooms que si hôte.
-- ---------------------------------------------------------------------------
create or replace function public.room_heartbeat(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me   uuid := auth.uid();
  v_code text := upper(trim(coalesce(p_code, '')));
  v_room public.online_rooms%rowtype;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  if not public._room_is_member(v_code, v_me) then
    raise exception using errcode = 'P0001', message = 'NOT_MEMBER';
  end if;

  update public.online_room_members m
     set last_seen_at = now()
   where m.code = v_code and m.user_id = v_me and m.left_at is null;

  if v_room.host_user_id = v_me then
    update public.online_rooms r
       set host_lease_until = now() + interval '15 seconds'
     where r.code = v_code
     returning * into v_room;
  end if;

  return jsonb_build_object(
    'version',          v_room.version,
    'host_user_id',     v_room.host_user_id,
    'host_lease_until', public._room_ts(v_room.host_lease_until),
    'server_now',       public._room_ts(now()),
    'members',          public._room_members_json(v_code)
  );
end;
$$;

comment on function public.room_heartbeat(text) is
  'Signale la présence de l''appelant (et renouvelle le bail s''il est hôte). Retour léger, sert de poll.';

-- ---------------------------------------------------------------------------
-- room_leave : départ explicite. En lobby, retire aussi le participant du
-- state ; si l'appelant est hôte, le bail expire immédiatement (relève).
-- ---------------------------------------------------------------------------
create or replace function public.room_leave(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     uuid := auth.uid();
  v_code   text := upper(trim(coalesce(p_code, '')));
  v_room   public.online_rooms%rowtype;
  v_state  jsonb;
  v_parts  jsonb;
  v_lease  timestamptz;
begin
  if v_me is null then
    raise exception using errcode = 'P0001', message = 'NOT_AUTHENTICATED';
  end if;

  select * into v_room from public.online_rooms r where r.code = v_code for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;

  update public.online_room_members m
     set left_at = now()
   where m.code = v_code and m.user_id = v_me and m.left_at is null;

  v_state := v_room.state;
  if v_room.status = 'lobby' then
    select coalesce(jsonb_agg(t.p order by t.ord), '[]'::jsonb)
      into v_parts
    from jsonb_array_elements(coalesce(v_state->'participants', '[]'::jsonb))
         with ordinality as t(p, ord)
    where nullif(t.p->>'userId','') is null or (t.p->>'userId')::uuid <> v_me;
    v_state := jsonb_set(v_state, '{participants}', v_parts, true);
  end if;

  v_lease := case when v_room.host_user_id = v_me then now() else v_room.host_lease_until end;

  update public.online_rooms r
     set state            = v_state,
         host_lease_until = v_lease,
         version          = r.version + 1
   where r.code = v_code
   returning * into v_room;

  return jsonb_build_object(
    'left',             true,
    'code',             v_room.code,
    'version',          v_room.version,
    'status',           v_room.status,
    'host_user_id',     v_room.host_user_id,
    'host_lease_until', public._room_ts(v_room.host_lease_until),
    'server_now',       public._room_ts(now())
  );
end;
$$;

comment on function public.room_leave(text) is
  'Départ explicite : left_at, retrait des participants en lobby, expiration du bail si l''appelant est hôte.';

revoke all on function public.room_get(text)                            from public, anon;
revoke all on function public.room_create(text, text, jsonb)            from public, anon;
revoke all on function public.room_join(text, text)                     from public, anon;
revoke all on function public.room_publish(text, bigint, jsonb, text)   from public, anon;
revoke all on function public.room_submit(text, int, jsonb)             from public, anon;
revoke all on function public.room_set_spectator(text, int, boolean)    from public, anon;
revoke all on function public.room_claim_host(text)                     from public, anon;
revoke all on function public.room_heartbeat(text)                      from public, anon;
revoke all on function public.room_leave(text)                          from public, anon;

grant execute on function public.room_get(text)                          to authenticated;
grant execute on function public.room_create(text, text, jsonb)          to authenticated;
grant execute on function public.room_join(text, text)                   to authenticated;
grant execute on function public.room_publish(text, bigint, jsonb, text) to authenticated;
grant execute on function public.room_submit(text, int, jsonb)           to authenticated;
grant execute on function public.room_set_spectator(text, int, boolean)  to authenticated;
grant execute on function public.room_claim_host(text)                   to authenticated;
grant execute on function public.room_heartbeat(text)                    to authenticated;
grant execute on function public.room_leave(text)                        to authenticated;

-- ============================================================================
-- 5. Purge
-- ============================================================================

-- Supprime les salons terminés ou inactifs depuis plus de 12 h. Renvoie le
-- nombre de lignes supprimées (les membres partent en cascade).
create or replace function public.purge_stale_online_rooms()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int;
begin
  delete from public.online_rooms r
   where r.status = 'finished'
      or r.updated_at < now() - interval '12 hours';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.purge_stale_online_rooms() is
  'Purge les salons terminés ou inactifs depuis plus de 12 h. Planifiée quotidiennement via pg_cron.';

revoke all on function public.purge_stale_online_rooms() from public, anon, authenticated;

-- Planification quotidienne — silencieusement ignorée si pg_cron est absent.
do $cronblock$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron indisponible : purge des salons non planifiée (%)', sqlerrm;
    return;
  end;

  begin
    perform cron.unschedule('purge-online-rooms');
  exception when others then
    null;
  end;

  perform cron.schedule('purge-online-rooms', '17 3 * * *',
                        'select public.purge_stale_online_rooms();');
exception when others then
  raise notice 'planification pg_cron ignorée (%)', sqlerrm;
end
$cronblock$;
