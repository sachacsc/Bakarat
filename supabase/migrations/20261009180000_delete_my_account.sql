-- Suppression de compte depuis l'app (App Store Review Guideline 5.1.1 (v) :
-- toute app qui crée des comptes doit permettre de les supprimer dans l'app).
--
-- delete_my_account : supprime le user courant de auth.users. Les FK
-- « on delete cascade » emportent profiles, games possédées (et leurs
-- manches / résultats / settlements), balances, device_tokens, placeholders
-- créés, online_rooms hébergées, participations online. Les participations
-- aux games des autres passent user_id à NULL (le siège reste, anonyme, pour
-- que l'historique des autres joueurs ne change pas). Les avatars du bucket
-- `avatars/<uid>/…` sont supprimés explicitement (pas de FK côté storage).
--
-- SECURITY DEFINER : le rôle authenticated n'a pas le droit de toucher
-- auth.users ni storage.objects ; la fonction ne vise que auth.uid().

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'Not authenticated'; end if;

  delete from storage.objects
   where bucket_id = 'avatars'
     and (storage.foldername(name))[1] = v_me::text;

  delete from auth.users where id = v_me;
end;
$$;

grant execute on function public.delete_my_account to authenticated;
revoke all on function public.delete_my_account from public, anon;
