# Audit connectivité — Bakarat Online (2026-09-25)

> Audit complet du mode **Online** (cartes virtuelles distribuées par le réseau) de l'app iOS
> Bakarat, mené par Fable 5.1 le 2026-09-25 avant relance du projet. Objectif : comprendre
> pourquoi « ça accroche », et concevoir un plan qui permette de jouer une soirée entière
> sans accroc — téléphone qui se verrouille, WiFi qui saute, hôte qui reçoit un appel.
>
> Périmètre : app iOS (`Bakarat/`) + backend Supabase (`supabase/`). La PWA web (`index.html`,
> PeerJS) est **hors périmètre** : protocole incompatible avec l'iOS, en maintenance.

---

## 1. Verdict en une page

Le mode Online ne peut **pas** fonctionner aujourd'hui, et ne pouvait fonctionner que par
beau temps en mai. Quatre causes, par ordre de gravité :

| # | Cause | Effet vécu | Preuve |
|---|-------|-----------|--------|
| **C1** | **Le projet Supabase est en pause** (`INACTIVE`, pause automatique du plan gratuit après 7 jours sans requête). Le DNS `wwutjnqchxzdfxmhfaaj.supabase.co` ne résout plus. | Rien ne marche : ni login, ni salon. | Management API `GET /v1/projects` → `status: INACTIVE`. Restauration lancée le 25/09 (`POST /restore` → 200). |
| **C2** | **SDK `supabase-swift` épinglé en v2.46.0**, version touchée par le bug [#999](https://github.com/supabase/supabase-swift/issues/999) : *« first channel subscribe stalls for 50 s – 7 min »* (v2.44.1 → v2.46.x). L'app coupe à 15 s. | « Le salon n'a pas pu être ouvert (délai dépassé) » quasi systématique à la création ou au join. | `Package.resolved` → 2.46.0. Bug corrigé par PR #1003 (juin), version courante **v2.55.2** (2026-09-09). |
| **C3** | **Architecture « hôte en mémoire + broadcast sans accusé »** : l'état de la partie n'existe que dans la RAM du téléphone de l'hôte ; chaque message Realtime est *fire-and-forget*, sans numéro de version ni relecture après reconnexion. | Un guest qui perd 2 s de réseau rate un snapshot et reste figé ; l'hôte qui verrouille son écran gèle la table ; une annonce perdue bloque le board jusqu'au timer (s'il est activé). | `OnlineGameService.swift` : `sendMessage` → `channel.broadcast` sans ack ; aucun `version` dans `OnlineRoom` ; aucune resynchronisation au `rejoin`. |
| **C4** | **Cycle de vie iOS ignoré** : aucun `scenePhase`, aucun `NWPathMonitor` ; et `OnlineLobbyView.onDisappear` appelle `service.leave()` — donc **changer d'onglet = quitter la partie**. La présence Realtime déclenche un **forfait immédiat** sans délai de grâce. | Une notification, un appel, un swipe vers l'onglet Comptes, ou un WiFi qui hoquette = « X a quitté », forfait pour la manche, retiré des manches suivantes. | grep `scenePhase` → 0 résultat ; `OnlineLobbyView.swift:38` ; `handlePresenceLeaves` → `forfeitFromBoard` sans grâce. |

Le SDK corrige aussi depuis : reconnexion automatique à un seul essai ([#1147](https://github.com/supabase/supabase-swift/issues/1147)),
subscribe qui ne converge plus jamais après un échec ([#1145](https://github.com/supabase/supabase-swift/issues/1145)),
deadlock watchdog main-thread ([#1154](https://github.com/supabase/supabase-swift/issues/1154)).
En revanche **[#579](https://github.com/supabase/supabase-swift/issues/579) (reconnexion au retour du réseau) est toujours ouvert** :
c'est à l'app de le faire.

**Conclusion** : corriger C1 + C2 rend le jeu *jouable par beau temps* en une demi-journée.
Jouer *sans accroc* demande de changer où vit la vérité (C3) et de respecter le cycle de vie
iOS (C4). C'est le plan `docs/PLAN_ONLINE_V2.md`.

---

## 2. Ce que fait le code aujourd'hui

### 2.1 Topologie

```
  Hôte (iPhone A)                       Supabase Realtime (WebSocket)              Guest (iPhone B)
  ┌───────────────────┐   broadcast "msg" {p: "<json>"}   ┌──────────────┐   broadcast   ┌───────────────┐
  │ OnlineRoom (RAM)  │ ───────────────────────────────▶  │ topic        │ ────────────▶ │ OnlineRoom    │
  │  + gameState      │ ◀───────────────────────────────  │ online:CODE  │ ◀──────────── │ (copie)       │
  │  + hands (TOUTES) │   hello / submit / spect / leave   └──────────────┘               └───────────────┘
  └───────────────────┘
          │ record_manche / ensure_game / touch_game_active (REST RPC)
          ▼
   Postgres : games, manches, manche_results, balances   ← seulement la FIN de chaque manche
```

* L'hôte est la **seule** source de vérité. Le serveur ne connaît ni le salon, ni la manche en
  cours, ni les mains. Il ne voit que le résumé de fin de manche (`record_manche`).
* Chaque changement d'état (chaque carte révélée !) = un **snapshot complet** de la room,
  encodé en JSON puis ré-encodé en string dans `{p: "..."}` (double encodage, taille ×1,3).
  `pastManches` grossit à chaque manche → le snapshot aussi.
* Toutes les mains sont diffusées à tout le monde (commentaire « debug » dans
  `OnlineGameState.hands` jamais retiré) : triche possible, et payload inutile.

### 2.2 Le chemin nominal (ce qui marche par beau temps)

1. `createRoom` → `openChannel` → `refreshSession` → `channel.subscribeWithError()` (timeout 15 s
   maison) → `track(presence)` → `ensure_game_and_participants` → heartbeat `touch_game_active` 30 s.
2. Guest : `joinRoom` → même `openChannel` → boucle `helloFromGuest` ×5 à 1 s → attend un
   `roomSnapshot`. Sans snapshot en 5 s : « Aucun salon trouvé ».
3. `startGame` : deck, mains, community pré-tirée ; broadcast ; `Task.sleep` 3 s ; 15 broadcasts
   de reveal à 0,7 s ; annonces ; `revealBoard` ; `sleep 5 s` ; board suivant… ; `mancheEnd` →
   `record_manche`.
4. Les guests envoient `submitAnnounce` ; l'hôte valide contre la main, broadcast, et révèle
   quand tous les éligibles ont soumis (ou au timer).

### 2.3 Les failles, une par une

| ID | Faille | Où | Conséquence |
|----|--------|----|-------------|
| F1 | Messages sans ack ni séquence. Un broadcast pendant une micro-coupure est perdu à jamais. | `sendMessage`, `broadcastSnapshot` | Guest figé sur une phase ancienne ; annonce perdue → board bloqué. |
| F2 | Pas de resynchronisation après `rejoin` du channel. Le guest ne renvoie `hello` qu'au join initial. | `openChannel` (hello une fois), aucun handler de `statusChange == .subscribed` | Après une coupure, le guest ne reçoit plus rien tant que l'hôte ne rebroadcast pas. |
| F3 | Présence = forfait immédiat, sans grâce. `wantsToSpectate = true` en prime. | `handlePresenceLeaves` | 2 s de WiFi perdu = joueur sorti de la manche **et** des suivantes. |
| F4 | Élection d'hôte par « plus petit seat connecté » côté guests, sans verrou. L'ex-hôte qui revient rebroadcast son état périmé. | `electNewHost`, `becomeHost`, `.snapshot` handler qui démote | Deux hôtes possibles pendant quelques secondes, états divergents, annonces perdues. |
| F5 | Aucun `scenePhase` : verrouillage d'écran = socket coupé par iOS ≈ 10–30 s plus tard ; rien au retour. | tout le module | L'hôte verrouille son téléphone pendant que les autres réfléchissent → table gelée. |
| F6 | `OnlineLobbyView.onDisappear → service.leave()` : fire au changement d'onglet (TabView). `didCallLeave` jamais remis à false. | `OnlineLobbyView.swift:38,520` | Un swipe vers « Comptes » = quitter la partie. |
| F7 | `openChannel` fait `signInAnonymously()` si `refreshSession` échoue (ex. réseau lent). | `openChannel` | Changement d'identité en pleine partie → le joueur devient un inconnu pour l'hôte. |
| F8 | Le tempo (`Task.sleep` 0,7 / 5 s) vit dans l'hôte. En arrière-plan, iOS suspend la Task ; au retour, elle reprend et pousse des snapshots périmés. | `revealCommunityProgressively`, `revealBoard` | Cartes qui « rejouent », phases qui sautent. |
| F9 | Le snapshot contient toutes les mains. | `OnlineGameState.hands` | Triche triviale (un proxy suffit), payload lourd. |
| F10 | `record_manche` sans retry ; en cas d'échec, la manche est perdue côté cloud. | `recordMancheToSupabase` | Historique / dettes faux après une coupure en fin de manche. |
| F11 | Timeout subscribe 15 s maison + SDK 2.46.0 qui met 4–7 min à joindre = échec systématique. | `openChannel`, `Package.resolved` | C2. |
| F12 | `OnlineRootView.swift` est du code mort (le flux est hébergé par `PlayRootView`) ; `CLAUDE.md` décrit encore PeerJS. | doc / code | Onboarding trompeur pour tout agent ou humain. |
| F13 | Aucun hook de test (auto-login, code de salon forcé, bots), aucun test du protocole. Les 3 tests unitaires portent sur l'encodage et Tricount. | `BakaratTests/`, `BakaratUITests/` | Impossible de prouver quoi que ce soit sans deux téléphones et deux humains. |
| F14 | Plan gratuit Supabase : pause après 7 jours sans requête. Aucun keep-alive. | infra | C1, et ça recommencera. |

### 2.4 Ce qui est bon et à garder

* La **logique de jeu** (`OnlineDealer`, `HandEvaluator`, scoring, tie-break, full board,
  rebid) est propre, pure, testable, conforme à `RULES.md`. On la garde telle quelle.
* Les modèles `OnlineRoom` / `OnlineGameState` sont `Codable` avec décodage tolérant : on peut
  les stocker en `jsonb` sans changement.
* Le schéma `games / manches / manche_results / balances` et les RPC `record_manche`,
  `ensure_game_and_participants`, `touch_game_active` restent la persistance longue durée.
* Les vues (`OnlineGameView`, `OnlineLobbyView`, sheets) consomment `service.room` : le
  remplacement du transport est invisible pour elles.
* Le build passe sous **Xcode 27 / iOS 26.5** sans erreur (44 warnings, tous bénins).

---

## 3. Cible : « la salle durable »

Principe : **la vérité vit dans Postgres, pas dans un téléphone.** L'hôte reste celui qui
*anime* (tempo des reveals) mais chaque état est écrit dans une ligne `online_rooms` versionnée ;
tout le monde relit cette ligne à chaque notification, à chaque retour au premier plan, et à
intervalle fixe. Perdre un message ne coûte plus rien : on relit.

```
                    ┌──────────────────────────── Postgres ────────────────────────────┐
                    │ online_rooms(code, version, state jsonb, host_user_id,          │
                    │              host_lease_until, status)                          │
                    │ online_room_members(code, user_id, display_name, last_seen_at)  │
                    │ RPC : room_create · room_join · room_get (mains expurgées)      │
                    │       room_publish(expected_version) · room_submit             │
                    │       room_claim_host · room_heartbeat · room_leave            │
                    └───────────▲───────────────────────────▲────────────────────────┘
        écrit (CAS)             │                           │            lit + écrit ses annonces
   ┌────────────────┐           │      postgres_changes     │           ┌────────────────┐
   │ Hôte (anime)   │───────────┘   « version a changé »    └───────────│ Guests         │
   │ lease 15 s     │◀──────────────── ping Realtime ──────────────────▶│ poll 5 s + ping│
   └────────────────┘                                                   └────────────────┘
```

* **CAS** (`expected_version`) : deux écritures concurrentes ne s'écrasent jamais ; le perdant
  relit et rejoue sa mutation (le pattern `updateGameState { gs in … }` existant s'y prête).
* **Bail d'hôte** (`host_lease_until`, renouvelé toutes les 5 s) : l'hôte qui disparaît est
  remplacé **de façon déterministe** (plus petit seat connecté réclame le bail, transaction
  Postgres = un seul gagnant). L'ex-hôte qui revient voit son `room_publish` refusé et se démote.
* **Grâce de présence** : `last_seen_at` par membre ; `connected=false` après 20 s de silence,
  forfait seulement après 60 s **ou** départ explicite. Le retour restaure tout.
* **Mains expurgées** : `room_get` ne renvoie que la main de l'appelant (toutes pour l'hôte ;
  toutes pour tout le monde en `mancheEnd`). La notification Realtime n'est qu'un *ping* ; l'état
  vient toujours de `room_get` — la taille du payload Realtime ne compte plus.
* **Cycle de vie iOS** : `scenePhase == .active` et `NWPathMonitor` satisfait → resync +
  rejoin ; le tempo de l'hôte devient **idempotent** (chaque pas relit l'état avant d'écrire :
  un pas rejoué après suspension ne fait rien).
* Quitter = **geste explicite** uniquement (bouton « Quitter », avec confirmation en partie).
* Effet de bord heureux : un client **web** redevient trivial (RPC + `postgres_changes`), sans
  PeerJS.

---

## 4. Ce qui a été fait pendant l'audit

* Restauration du projet Supabase lancée (`POST /v1/projects/wwutjnqchxzdfxmhfaaj/restore`
  → HTTP 200, statut `COMING_UP`).
* Build de vérification `xcodebuild build` sur iPhone 17 Pro (iOS 26.5) : **succès**.
* Inventaire des 27 RPC SQL et des tables ; aucune table d'état de salon n'existe (confirme C3).

## 5. Sources

* Issues supabase-swift : [#999](https://github.com/supabase/supabase-swift/issues/999),
  [#1147](https://github.com/supabase/supabase-swift/issues/1147),
  [#1145](https://github.com/supabase/supabase-swift/issues/1145),
  [#1249](https://github.com/supabase/supabase-swift/issues/1249),
  [#1154](https://github.com/supabase/supabase-swift/issues/1154),
  [#595](https://github.com/supabase/supabase-swift/issues/595),
  [#579](https://github.com/supabase/supabase-swift/issues/579).
* Releases : [supabase-swift v2.55.2](https://github.com/supabase/supabase-swift/releases).
