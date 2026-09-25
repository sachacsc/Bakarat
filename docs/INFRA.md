# Infra Bakarat — clés, comptes, automatisations

> Tout ce qu'il faut savoir pour faire tourner le backend et les loops sans fouiller.
> Aucun secret ici : seulement leurs emplacements.

## Supabase

| Élément | Valeur |
|---------|--------|
| Projet | `wwutjnqchxzdfxmhfaaj` (nom « Baccarat », eu-west-1, Postgres 17) |
| URL | `https://wwutjnqchxzdfxmhfaaj.supabase.co` |
| Clé anon (publique) | `supabase-config.js` (web) et `Bakarat/Bakarat/Supabase/SupabaseConfig.swift` (iOS) |
| PAT de gestion (compte Supabase, partagé avec Zmeo) | `~/.zmeo-supabase.env` → `SUPABASE_PAT` (0600) |
| Clé `service_role` | jamais sur disque ; à la demande via `GET /v1/projects/<ref>/api-keys?reveal=true` avec le PAT |

**Plan gratuit → pause automatique après 7 jours sans requête.** Le projet était `INACTIVE` de
mai à septembre 2026 ; DNS mort, tout échouait. Restauration : `POST https://api.supabase.com/v1/projects/<ref>/restore`.
Parade : `scripts/supabase-keepalive.sh` (launchd `com.bakarat.keepalive`, 09:15 tous les jours,
log `~/Library/Logs/bakarat-keepalive.log`) — une requête REST par jour, restauration si besoin.

**Migrations** : `supabase/migrations/*.sql`, appliquées par `supabase db push` (CLI liée) ou, plus
simple sans mot de passe DB, par l'API de gestion `POST /v1/projects/<ref>/database/query`
(voir `scripts/sql-smoke-online-rooms.py` pour le pattern). Toujours vérifier après coup
`select version from supabase_migrations.schema_migrations`.

## Comptes QA (tests protocole, tour, duel)

| Email | Rôle |
|-------|------|
| `bakaratqa.host@bakarat.test` | hôte |
| `bakaratqa.g1@bakarat.test`, `g2`, `g3` | invités / bots |

Mot de passe commun et URL/anon : `~/.bakarat-qa.env` (0600, variables `BAKARAT_QA_PASSWORD`,
`BAKARAT_SUPABASE_URL`, `BAKARAT_SUPABASE_ANON`). Créés le 2026-09-25 via l'API admin GoTrue
(`email_confirm: true`). Profils `QA-host`, `QA-g1`… auto-créés par le trigger `handle_new_user`.

## Toolchain

* Xcode 27 (27A266a), simulateurs iOS 26.5 (iPhone 17 Pro booté par défaut).
* DerivedData dédiée : `~/Library/Caches/bakarat-dd` (jamais `/tmp` : macOS purge).
* SDK `supabase-swift` **2.55.2** (bumpé le 2026-09-25 ; 2.46.0 avait le bug #999).

## Automatisations (launchd, Mac de l'owner)

| Label | Heure (Paris) | Rôle |
|-------|---------------|------|
| `com.bakarat.keepalive` | 09:15 | keep-alive Supabase |
| `com.bakarat.online-loop` | 15:00 | (P3) tour + duel + juge → `audits/online/` |

Le tour Zmeo tourne à 13:00 : ne pas chevaucher (CPU + simulateurs).
