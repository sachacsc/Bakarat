-- Robustesse Online v2 avant lancement App Store (revue 2026-10-09).
--
-- 1. record_manche : un participant (pas seulement l'owner) peut enregistrer
--    une manche d'une game existante → le comptage survit à la relève d'hôte.
-- 2. room_create : un hôte ne peut plus écraser son propre salon vivant tant
--    que d'autres membres y sont présents (ils finissaient NOT_MEMBER, figés).
-- 3. room_publish : ne teste plus le bail, seulement host_user_id (fin du
--    flap hôte/invité au retour d'arrière-plan).
-- 4. room_join : ROOM_FULL au-delà de 8 joueurs ; l'hôte qui rejoint renouvelle
--    son bail.
-- Idempotent (create or replace), à appliquer via
-- scripts/supabase-apply-migration.py (geste mandaté).

-- ===== 1. record_manche =====
create or replace function public.record_manche(
  p_game_id        uuid,
  p_mode           text,
  p_line_price     numeric,
  p_currency       text,
  p_settings_json  jsonb,
  p_participants   jsonb,
  p_manche_number  int,
  p_dealer_seat    int,
  p_num_active     int,
  p_board_results  jsonb,
  p_full_board_seat int,
  p_results_per_seat jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_game_id   uuid := p_game_id;
  v_manche_id uuid;
  v_caller    uuid := auth.uid();
  p           jsonb;
  r           jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated';
  end if;

  if v_game_id is null then
    insert into public.games (owner_user_id, mode, line_price, currency, settings_json)
    values (v_caller, p_mode, p_line_price, p_currency, coalesce(p_settings_json, '{}'::jsonb))
    returning id into v_game_id;

    for p in select * from jsonb_array_elements(p_participants) loop
      insert into public.game_participants (game_id, seat_index, user_id, placeholder_id, guest_name)
      values (
        v_game_id,
        (p->>'seat_index')::int,
        nullif(p->>'user_id','')::uuid,
        nullif(p->>'placeholder_id','')::uuid,
        nullif(p->>'guest_name','')
      );
    end loop;
  else
    -- Owner OU participant (même règle que ensure_game_and_participants) :
    -- après une relève d'hôte Online, c'est un autre joueur qui enregistre.
    if not exists (
      select 1 from public.games g
      where g.id = v_game_id
        and (g.owner_user_id = v_caller
             or exists (select 1 from public.game_participants gp
                        where gp.game_id = g.id and gp.user_id = v_caller))
    ) then
      raise exception 'Game not found or unauthorized';
    end if;
  end if;

  insert into public.manches (game_id, manche_number, dealer_seat, line_price, num_active, board_results, full_board_seat)
  values (v_game_id, p_manche_number, p_dealer_seat, p_line_price, p_num_active, p_board_results, p_full_board_seat)
  on conflict (game_id, manche_number) do nothing
  returning id into v_manche_id;

  if v_manche_id is null then
    return v_game_id;
  end if;

  for r in select * from jsonb_array_elements(p_results_per_seat) loop
    insert into public.manche_results (manche_id, seat_index, delta, boards_won_json)
    values (
      v_manche_id,
      (r->>'seat_index')::int,
      (r->>'delta')::numeric,
      coalesce(r->'boards_won_json', '[]'::jsonb)
    );
  end loop;

  -- _apply_balances_for_manche : on garde l'appel pour le legacy ledger.
  -- N'affecte plus les Dettes (qui sont recalculées on-the-fly côté client)
  -- mais entretient la table balances pour rétrocompat éventuelle.
  perform public._apply_balances_for_manche(v_manche_id);

  return v_game_id;
end;
$$;

-- ===== 2. room_create =====
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
      -- Même hôte : on ne remplace PAS un salon vivant où d'autres membres
      -- sont encore présents (vus < 60 s) — sinon ils sont éjectés en silence
      -- (NOT_MEMBER) et leur écran se fige (C-0002/0003/0004).
      if v_existing.status in ('lobby','playing') and exists (
        select 1 from public.online_room_members m
        where m.code = v_code and m.user_id <> v_me
          and m.left_at is null
          and m.last_seen_at > now() - interval '60 seconds'
      ) then
        raise exception using errcode = 'P0001', message = 'CODE_TAKEN';
      end if;
      -- Salon terminé ou abandonné : on remplace (cascade sur les membres).
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

-- ===== 3. room_publish =====
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

  -- Seul host_user_id fait foi : la relève (room_claim_host) le change sous
  -- verrou de ligne. Tester aussi le bail faisait flapper un hôte revenu
  -- d'arrière-plan (NOT_HOST → guest → heartbeat renouvelle → hôte…).
  if v_room.host_user_id <> v_me then
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

-- ===== 4. room_join =====
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

  -- Cap : 8 joueurs max (au-delà, OnlineDealer ne peut plus distribuer).
  if not exists (
    select 1 from jsonb_array_elements(coalesce(v_room.state->'participants', '[]'::jsonb)) as p
    where nullif(p->>'userId','') is not null and (p->>'userId')::uuid = v_me
  ) and jsonb_array_length(coalesce(v_room.state->'participants', '[]'::jsonb)) >= 8 then
    raise exception using errcode = 'P0001', message = 'ROOM_FULL';
  end if;

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
         version = r.version + 1,
         -- L'hôte qui revient (« Reprendre ») garde la main : bail renouvelé.
         host_lease_until = case when r.host_user_id = v_me
                                 then now() + interval '15 seconds'
                                 else r.host_lease_until end
   where r.code = v_code;

  return public.room_get(v_code);
end;
$$;
