-- ============================================================================
-- Mode Flash : cartes publiques visibles des guests
-- ----------------------------------------------------------------------------
-- `_room_state_redact` (20260925100000_online_rooms.sql) réduisait
-- `gameState.hands` à la seule main de l'appelant. Or en mode Flash
-- (`state.flashMode = true`, cf. RULES.md § « Mode Flash ») les DERNIÈRES
-- cartes distribuées de chaque joueur sont publiques :
--   6 cartes → les 2 dernières ; 5 cartes → la dernière ; 4 cartes → aucune.
-- Depuis l'expurgation, les invités ne voyaient plus ces cartes ouvertes.
--
-- Nouvelle règle (appelant non-hôte, phase ≠ `mancheEnd` — room_get ne
-- l'appelle déjà que dans ce cas ; la garde de phase est redondante mais
-- rend la fonction sûre isolément) :
--   * siège de l'appelant : main complète ;
--   * autres sièges, Flash actif : les k derniers éléments du tableau, avec
--     k = greatest(0, longueur − 4) ; entrée omise si k = 0 ;
--   * autres sièges, Flash inactif : entrée omise (comportement inchangé) ;
--   * `pendingFlop` / `pendingTurns` / `pendingRivers` / `burns` : vidés.
-- « Dernières distribuées » = fin du tableau JSON : `OnlineDealer.dealHands`
-- fait `append` à chaque tour de distribution.
-- Signature, search_path et grants identiques à la version précédente.
-- ============================================================================

create or replace function public._room_state_redact(p_state jsonb, p_seat int)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_out   jsonb := p_state;
  v_gs    jsonb := p_state->'gameState';
  v_flash boolean := coalesce(p_state->>'flashMode', '') = 'true'
                     and coalesce(p_state->'gameState'->>'phase', '') <> 'mancheEnd';
  v_hands jsonb;
  v_kept  jsonb := '{}'::jsonb;
  v_key   text;
  v_hand  jsonb;
  v_len   int;
  v_k     int;
begin
  if v_gs is null or jsonb_typeof(v_gs) <> 'object' then
    return p_state;
  end if;

  v_hands := v_gs->'hands';
  if v_hands is not null and jsonb_typeof(v_hands) = 'object' then
    for v_key, v_hand in select e.key, e.value from jsonb_each(v_hands) e loop
      if p_seat is not null and v_key = p_seat::text then
        v_kept := v_kept || jsonb_build_object(v_key, v_hand);
      elsif v_flash and jsonb_typeof(v_hand) = 'array' then
        v_len := jsonb_array_length(v_hand);
        v_k   := greatest(0, v_len - 4);
        if v_k > 0 then
          v_kept := v_kept || jsonb_build_object(v_key, (
            select jsonb_agg(t.card order by t.idx)
            from jsonb_array_elements(v_hand) with ordinality as t(card, idx)
            where t.idx > v_len - v_k
          ));
        end if;
      end if;
    end loop;
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

comment on function public._room_state_redact(jsonb, int) is
  'State expurgé pour un non-hôte : sa main complète ; en mode Flash, les k = longueur − 4 dernières cartes des autres sièges (publiques) ; pending*/burns vidés.';

revoke all on function public._room_state_redact(jsonb, int) from public, anon, authenticated;
