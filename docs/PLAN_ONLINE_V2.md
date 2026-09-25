# Plan d'action — Online « sans accroc » (v2, 2026-09-25)

> Suite de `AUDIT_CONNECTIVITE_2026-09-25.md`. Diagnostic et plan : Fable 5.1.
> Implémentation : agents Opus/Sonnet sous supervision, vérification sur simulateur par Fable.
> Chaque ticket est atomique, vérifiable, et livré par PR (ou commit direct sur `main` quand
> l'owner l'a demandé). Aucune régression visible n'est acceptée.

## Phases

| Phase | But | Tickets | Preuve |
|-------|-----|---------|--------|
| **P0 — Remettre le courant** | Backend vivant, SDK sain, hooks de test | T01–T05 | Build vert + création/join d'un salon en < 5 s sur simulateur |
| **P1 — La salle durable** | État en Postgres, versionné, expurgé | T10–T15 | Tests protocole in-process verts (2 services, 1 process) |
| **P2 — Cycle de vie & présence** | scenePhase, réseau, bail d'hôte, grâce | T20–T24 | Scénarios chaos verts (coupure guest, coupure hôte, verrouillage) |
| **P3 — Les loops** | Tour, duel 2 simulateurs, juge, registre, launchd | T30–T36 | `audits/online/OPEN.md` publié chaque jour |
| **P4 — Lancement** | TestFlight, télémétrie connectivité, keep-alive | T40–T43 | Build TestFlight + snapshot télémétrie J+1 |

---

## P0 — Remettre le courant

* **T01 — Restaurer Supabase** *(fait le 25/09 par l'API, à vérifier `ACTIVE_HEALTHY`)*.
  Puis `supabase migration list` : le schéma distant doit correspondre aux 17 migrations du dépôt.
* **T02 — Bump `supabase-swift` → 2.55.2** (`Package.resolved` + pbxproj `minimumVersion`).
  Compiler, corriger les APIs renommées. Supprimer le `withTimeout(15)` maison au profit d'un
  timeout raisonnable (30 s) *ou* le garder s'il compile : le vrai fix est la version.
* **T03 — Retirer les pièges évidents** : (a) `signInAnonymously` en fallback d'`openChannel` →
  erreur claire à la place ; (b) `OnlineLobbyView.onDisappear → leave` → retiré ; quitter =
  bouton explicite (lobby : back = quitter avec confirmation si ≥ 2 joueurs ; partie : sheet
  « Quitter la partie » existante). (c) `OnlineRootView.swift` mort → supprimé.
* **T04 — Hooks de test au lancement** (DEBUG seulement, pattern Zmeo) :
  `-autoLoginEmail/-autoLoginPassword`, `-qaRoomCode ABCD` (code forcé à la création),
  `-autoJoinCode ABCD` (join automatique au lancement), `-qaBots N` (voir T33),
  `-chaos <profil>` (voir T24). Comptes QA `bakaratqa.host@bakarat.test`,
  `bakaratqa.g1..g3@bakarat.test` créés via Management API (mot de passe dans
  `~/.bakarat-qa.env`, 0600).
* **T05 — Keep-alive Supabase** : la loop quotidienne (T35) compte comme activité ; en plus, un
  `launchd` léger `com.bakarat.keepalive` fait un `GET /rest/v1/` toutes les 24 h. Documenter
  dans `docs/INFRA.md`.

## P1 — La salle durable (backend + transport)

* **T10 — Migration `online_rooms`** :
  ```sql
  create table public.online_rooms (
    code            text primary key,                    -- 4 chars
    host_user_id    uuid not null references auth.users(id),
    host_lease_until timestamptz not null default now() + interval '15 seconds',
    version         bigint not null default 1,
    status          text not null default 'lobby' check (status in ('lobby','playing','finished')),
    state           jsonb not null,                      -- OnlineRoom encodé (sans champs dérivés)
    cloud_game_id   uuid references public.games(id),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
  );
  create table public.online_room_members (
    code         text references public.online_rooms(code) on delete cascade,
    user_id      uuid references auth.users(id) on delete cascade,
    display_name text not null,
    seat_hint    int,
    joined_at    timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    left_at      timestamptz,
    primary key (code, user_id)
  );
  ```
  RLS : `select` sur les deux tables si `auth.uid()` est membre non parti (helper SECURITY DEFINER
  `is_room_member(code)`, jamais de policies croisées — leçon `my_game_ids()`). Aucun `insert/update`
  direct : tout passe par RPC. `alter publication supabase_realtime add table online_rooms;`
  `replica identity full` inutile (on n'écoute que `UPDATE` et on relit via `room_get`).
  Purge : `status='finished'` ou `updated_at < now() - 12 h` → cron `pg_cron` quotidien.
* **T11 — RPC (SECURITY DEFINER, `search_path = public`)** :
  * `room_create(p_code text default null, p_display_name text, p_state jsonb) → jsonb` : code aléatoire
    si null (retry sur collision), membre hôte, bail. Retour : ligne complète (vue `room_view`).
  * `room_join(p_code, p_display_name) → jsonb` : upsert membre, ajoute le participant dans
    `state.participants` si absent (jsonb), `version+1`. Erreur `ROOM_NOT_FOUND` explicite.
  * `room_get(p_code) → jsonb` : ligne + `state` **expurgé** : `state.gameState.hands` réduit à la
    main de l'appelant, sauf si appelant = `host_user_id` ou `phase = 'mancheEnd'`. Renvoie aussi
    `members` (avec `last_seen_at`) et `server_now`.
  * `room_publish(p_code, p_expected_version bigint, p_state jsonb, p_status text) → jsonb` :
    hôte seulement (`host_user_id = auth.uid()` **et** bail non expiré, sinon `NOT_HOST`) ;
    si `version <> expected` → renvoie `{conflict: true, room: <ligne expurgée>}` sans écrire ;
    sinon écrit, `version+1`, renouvelle le bail, renvoie `{conflict:false, room}`.
    **Fusion des annonces** : le serveur ré-injecte dans `p_state` les `submissions` présentes en
    base et absentes du payload (un guest a soumis entre la lecture et l'écriture de l'hôte) —
    ainsi l'hôte ne peut jamais effacer une annonce.
  * `room_submit(p_code, p_seat, p_submission jsonb) → jsonb` : vérifie que le seat appartient à
    l'appelant, que la phase est `announcing` ou `tiebreakAnnouncing`, que les cartes ⊆ main du
    seat, que le seat n'a pas déjà soumis ; `jsonb_set` dans `submissions` (ou dans le dernier
    `tiebreakBoards[-1].submissions`), `version+1`.
  * `room_set_spectator(p_code, p_seat, p_wants bool)` : même modèle.
  * `room_claim_host(p_code) → jsonb` : autorisé si bail expiré **ou** appelant déjà hôte ;
    met `host_user_id`, bail, `state.hostUserId`, `participants[].isHost`, `version+1`. Un seul
    gagnant (row lock `for update`).
  * `room_heartbeat(p_code) → jsonb` : `last_seen_at = now()` pour l'appelant ; si hôte, renouvelle
    le bail. Renvoie `{version, host_user_id, host_lease_until, server_now, members}` (léger :
    sert de poll).
  * `room_leave(p_code)` : `left_at = now()` ; si lobby, retire des `participants` ; si hôte,
    expire le bail immédiatement (les autres réclament).
  Tests SQL (pgTAP ou script `scripts/sql-smoke.py` via Management API) : CAS, fusion des
  annonces, expurgation, claim concurrent.
* **T12 — `RoomTransport` (Swift)** : nouveau fichier `Core/Online/Service/RoomTransport.swift`.
  Responsabilités : appels RPC typés, channel `postgres_changes` (`UPDATE` sur `online_rooms`,
  `filter: code=eq.CODE`) traité comme **ping** → `room_get` ; poll `room_heartbeat` toutes les
  5 s en partie (2 s en lobby), qui relit `room_get` si `version` a bougé ; file d'attente
  d'écritures sérialisée (une `Task` à la fois). Expose `AsyncStream<RoomSnapshot>` + `connectionState`
  (`connected / reconnecting / offline`) pour l'UI.
* **T13 — Refonte `OnlineGameService` sur `RoomTransport`** : on garde toute la logique de jeu
  (T = 900 lignes de scoring/reveal/tie-break inchangées). On remplace : `openChannel`,
  `sendMessage`, `handleIncoming`, `broadcastSnapshot`, presence, élection, resume UserDefaults.
  * `updateGameState { … }` devient `mutate { room in … }` = boucle `room_get → mutate → room_publish`
    avec rejeu sur `conflict` (max 5).
  * Les annonces des guests passent par `room_submit` ; l'hôte observe les changements de version
    et appelle `checkAllSubmitted()` (idempotent) à chaque snapshot reçu.
  * Le tempo de l'hôte (`revealCommunityProgressively`, pauses) est réécrit en **pas idempotents**
    : chaque pas relit l'état ; si la phase ou le nombre de cartes attendu n'est plus celui prévu,
    le pas ne fait rien. Un pas rejoué après suspension est donc inoffensif.
  * `resumeAsHost` disparaît : la reprise = `room_get` + `room_claim_host`.
* **T14 — Expurgation côté client** : `OnlineGameView` / `AllHandsSheet` doivent tolérer
  `hands` partiel (déjà `[Int: [Card]]`, vérifier les `!`).
* **T15 — `record_manche` fiable** : appel idempotent (clé `manche_number` + `cloud_game_id`,
  le RPC existant doit être rendu `on conflict do nothing` ou vérifié) + retry 3× avec backoff ;
  si échec définitif, `state.pendingRecords` conserve la manche et le prochain hôte retente.

## P2 — Cycle de vie & présence

* **T20 — `scenePhase`** : dans `OnlineLobbyView`/`OnlineGameView` (ou un `ViewModifier`
  `.roomLifecycle(service)`) : `.active` → `transport.resync()` (rejoin channel si statut ≠
  `subscribed`, `room_get`, reprise heartbeat) ; `.background` → arrêt des Tasks de tempo
  (elles se relancent à `.active` via `resumeFromCurrentPhase`, idempotent).
* **T21 — `NWPathMonitor`** : chemin satisfait après une coupure → `resync()` immédiat (ne pas
  attendre le heartbeat SDK de 25 s — #579).
* **T22 — Bail d'hôte + relève** : heartbeat hôte 5 s ; guests : si `host_lease_until < server_now - 5 s`
  → le plus petit seat connecté appelle `room_claim_host` ; en cas de succès → `becomeHost` →
  `resumeFromCurrentPhase`. Ex-hôte : `room_publish` → `NOT_HOST` → `role = .guest` + resync.
  Bannière UI « X anime maintenant la partie ».
* **T23 — Grâce de présence** : `connected` dérivé de `members.last_seen_at` (calculé par l'hôte
  à chaque tick) ; forfait (`forfeitFromBoard`) seulement après 60 s **ou** `room_leave` /
  kick ; retour → `connected = true`, `wantsToSpectate` inchangé (plus de mise en spectateur
  automatique). UI : pastille « reconnexion… » sur le siège, timer visible sur l'hôte.
* **T24 — Chaos (DEBUG)** : `ChaosProfile` injecté par `-chaos <nom>` : `guest-blip-10s`
  (coupe le socket 10 s en `announcing`), `host-lock-30s` (coupe l'hôte 30 s en `boardReveal`),
  `drop-30pct` (ignore 30 % des pings), `slow-3s` (latence RPC), `double-host` (deux publish
  concurrents). Implémenté dans `RoomTransport` (pas dans la logique de jeu).

## P3 — Les loops (à la Zmeo)

* **T30 — Tests unitaires purs** `BakaratTests/OnlineRulesTests` : dealer (ordre RULES.md),
  scoring, full board, tie-break, rebid, idempotence des pas de tempo (fonction pure
  `nextStep(state) -> state?`). Sans réseau. Tournent dans la loop et en CI.
* **T31 — Tests protocole in-process** `BakaratTests/OnlineProtocolLiveTests` : deux (ou trois)
  `OnlineGameService` dans le même process, deux `SupabaseClient` (comptes QA), contre le
  Supabase réel : create/join/start/annonces/reveal/mancheEnd/`record_manche` ; puis chaque
  profil chaos (T24) avec assertion de **convergence** (`room.version` égal partout, phase
  attendue atteinte en < N s). Marqués `.tags(.live)`, sautés si `BAKARAT_LIVE_TESTS != 1`.
* **T32 — Tour XCUITest** `BakaratUITests/BakaratTourUITests` : launch → auto-login → créer
  salon (code forcé) → **bots** (T33) rejoignent → démarrer → captures à chaque phase → annonces
  via l'UI → fin de manche → historique. Assertions d'expérience : loader < 5 s, phase suivante
  < 8 s, aucun écran figé > 15 s (capture `*-DIAG-*` + `XCTFail`). Clair + sombre.
* **T33 — Bots in-app** (DEBUG) : `-qaBots N` lance N `OnlineGameService` dans l'app avec des
  clients QA distincts, qui rejoignent `-qaRoomCode`, annoncent une catégorie valide aléatoire
  après 1–3 s, et (profil chaos) se coupent/reviennent. Permet le tour sur **un** simulateur.
* **T34 — Duel deux simulateurs** `scripts/duel.sh` : `build-for-testing` une fois, puis
  `test-without-building` en parallèle sur `bakarat-host` et `bakarat-guest` (deux sims dédiés,
  DerivedData dédiée, jamais `/tmp`) : hôte crée `QATEST`, guest le rejoint ; scénarios :
  (1) manche complète, (2) guest `press(.home)` 20 s pendant `announcing` → revient → soumet,
  (3) hôte `press(.home)` 30 s pendant `boardReveal` → guest reprend l'animation → hôte revient
  démoté. Chaque scénario = captures + assertions de convergence via `room_get` (REST depuis le
  test).
* **T35 — Runner + launchd** `scripts/online-loop.sh` + `~/Library/LaunchAgents/com.bakarat.online-loop.plist`
  (15:00 Paris, après le tour Zmeo de 13:00) : T30 → T31 → T32 (light/dark) → T34 ; exporte
  `audits/online/<date>/` (captures, xcresult, `summary.json` : durée par phase, reconnexions,
  conflits CAS, relèves d'hôte). Le run compte comme keep-alive Supabase.
* **T36 — Juge + registre** `scripts/online-judge.py` (fork de `ui-tour-judge.py`, `claude -p`
  sur l'abonnement, jamais la clé API) : relit captures + `summary.json`, tient
  `audits/online/registry.json` → `OPEN.md` (items `B-xxxx`, cycle open → still → gone → fixed),
  rapport du jour, publication via l'API Contents GitHub (jamais le working tree).
  Une loop `bakarat-online` (routine cloud) lit `OPEN.md` et corrige, 1 PR par item.

## P4 — Lancement

* **T40 — Télémétrie connectivité** : table `client_events` (RLS insert-only par l'auteur) ;
  l'app y écrit `subscribe_ms`, `resync`, `cas_conflict`, `host_claim`, `record_manche_retry`,
  erreurs. `scripts/online-telemetry.py` → `audits/online/telemetry/<date>.md`, lu par le juge.
* **T41 — TestFlight** : `scripts/release-testflight.sh` (port du script Zmeo, cert `zmeo-dist`),
  build 10, notes « Online v2 ». Test réel à 3–4 joueurs avec chaos manuel (mode avion).
* **T42 — Doc** : `CLAUDE.md` réécrit (PeerJS → salle durable ; carte des fichiers ; hooks ;
  loops), `Bakarat/README.md`, `docs/INFRA.md` (clés, keep-alive, comptes QA).
* **T43 — Web (option)** : brancher `index.html` sur les RPC `room_*` + `postgres_changes` et
  retirer PeerJS. Seulement si l'owner veut jouer iOS ↔ web.

---

## Règles pour les agents d'implémentation

1. Lire `RULES.md`, `docs/AUDIT_CONNECTIVITE_2026-09-25.md`, ce plan, puis le code visé.
2. **Ne jamais toucher la logique de jeu** (scoring, dealer, tie-break) hors T30 (tests) — sauf
   bug prouvé par un test.
3. Chaque migration SQL est **dans la PR**, appliquée par `supabase db push` (ou Management API
   `database/query`) par Fable, jamais par un agent.
4. Un agent sans Xcode ne prétend jamais « build vert ». La preuve de build et de simulateur est
   produite par Fable sur le Mac.
5. Pas de `git add -A` ; pas de push de `xcuserstate`.
6. Français dans les commentaires et l'UI (comme le reste du code), anglais pour les identifiants.
