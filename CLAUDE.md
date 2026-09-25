# Baccarat 3-boards — Project guide

> Quick onboarding for AI agents (and humans) working on this codebase.

## Two clients, one backend

This repo holds **two** front-ends targeting the same Supabase backend :

| Folder       | What it is                              | Status                |
|--------------|------------------------------------------|-----------------------|
| `/` (root)   | Web app (vanilla JS, PWA on GH Pages)    | Live, in maintenance  |
| `/Bakarat/`  | Native SwiftUI iOS app                   | In active development |

Both share the same DB schema, RLS, RPCs, and Storage bucket. Migrations live under `/supabase/migrations/` and apply to **both** clients automatically — never reimplement business logic in only one place.

Game rules : `RULES.md`. Read once before touching scoring / evaluation.

## What is this

A web + iOS app for the **Baccarat 3-boards** card game variant. Two play modes:
- **Compteur** — physical cards, the app tracks scores (Tricount-style multi-counter)
- **Online** — virtual cards distributed over the network

Auth + persistence via **Supabase**. Each user has an account; their games and balances are saved cloud-side. The web is deployed as a **PWA** on GitHub Pages. The iOS app is published via the App Store (planned).

For iOS-specific onboarding, see `/Bakarat/README.md`.

Game rules are documented in [`RULES.md`](RULES.md) — read it once before working on game logic.

## Tech stack

- **Frontend** : vanilla JS (ES modules) + CSS, no framework
- **Auth + DB + Storage** : Supabase (Postgres, Auth, Realtime, Storage)
- **Realtime multiplayer (iOS)** : « salle durable » — état versionné dans Postgres (`online_rooms`), RPC `room_*`, Realtime = ping + `room_get`. Voir `docs/PLAN_ONLINE_V2.md`. (Le web utilise encore PeerJS : legacy, incompatible avec l'iOS.)
- **Card assets** : `Xadeck/xCards` via jsdelivr CDN (faces + back, all 750×1050 / 5:7)
- **PWA** : `manifest.json` + `sw.js` (service worker, network-first HTML, cache-first assets)

## File map

```
/Baccarat/
├── index.html              UI shell (HTML + CSS + main module entry)
├── supabase-config.js      Project URL + anon key (loaded as classic script before module)
├── manifest.json           PWA metadata
├── sw.js                   Service worker
├── *.png                   App icons (192/512/180 + maskable)
├── qr-app.png              QR pointing at the GH Pages URL
├── RULES.md                Game rules reference
├── CLAUDE.md               This file
├── src/
│   ├── utils.js            Pure helpers : uid, escapeHTML, fmtMoney, formatAgo
│   ├── game/
│   │   ├── categories.js   CATEGORIES, CAT_RANK, CAT_BY_ID, MULTI_OPTIONS
│   │   ├── deck.js         SUITS, RANKS, SUIT_SYMBOLS, SUIT_COLORS, RANK_DISPLAY, buildDeck, shuffleDeck
│   │   ├── eval.js         evaluate5, evaluateBest, compareHands, validateAnnounce, autoPickCards, computeNuts
│   │   └── cards.js        CARDS_CDN_BASE, cardImgURL, cardBackURL, preloadCardImages, renderCardHTML
│   └── (TODO — to extract incrementally)
│       ├── auth/           gate (login/signup/forgot/reset), profile modal
│       ├── shell/          tabbar, sheets, navigation titles
│       ├── online/         PeerJS, host/guest, game state, render
│       ├── counter/        multi-counter list, setup, manche, history
│       ├── debts/          balances rendering
│       ├── cloud/          cloudRecordCounterManche, saveOnlineState
│       └── state.js        global state + load/save/migrate
└── supabase/
    ├── config.toml         Auth + storage config (synced via `supabase config push`)
    └── migrations/         SQL migrations applied via `supabase db push`
```

The bulk of the code still lives inside `index.html`'s main `<script type="module">` block — extraction is **incremental**. Move things into modules when they grow large enough to be confusing inline.

## Running / deploying

**Local dev:** any static server from the repo root.
```
python3 -m http.server 8080
# open http://localhost:8080
```

**Deploy:** push to `main` → GitHub Pages auto-rebuilds at https://sachacsc.github.io/Baccarat/ within 1-2 minutes. There is no build step.

**Supabase CLI** (project linked already):
```
supabase migration new <name>     # create a migration file
supabase db push                  # apply pending migrations to remote
supabase config push              # sync supabase/config.toml to remote
```

The Supabase project ref is `wwutjnqchxzdfxmhfaaj` (West EU). The anon key in `supabase-config.js` is public by design — RLS protects the data.

## State shape (global `state` object)

```js
{
  mode: 'counter' | 'online',  // active tab "mode"
  activeTab: 'online' | 'counter' | 'debts',

  // ===== Multi-counter (Tricount-style) =====
  counters: [
    {
      id, name, linePrice, currency, players, scores, history,
      currentManche, dealerIdx, configured,
      cloudGameId, cloudSeatMap,
      createdAt, lastUsedAt,
    }
  ],
  activeCounterId,  // null = list view, set = detail view

  // ===== Active counter fields projected here so existing code keeps working =====
  players, scores, history, currentManche, dealerIdx, configured, linePrice,
  cloudGameId, cloudSeatMap,
}
```

**Critical pattern:** when a counter is active, its fields (`players`, `scores`, etc.) are projected onto the root of `state`. `save()` runs `syncStateToActiveCounter()` first to reverse-project mutations back into `state.counters[i]`. This keeps the existing render/validation functions untouched.

When switching counters: `loadCounterIntoState(c)` copies fields in. When closing back to list: `clearActiveStateFields()` resets them.

## Auth flow

```
User opens app
  → applyAuthGate()
    → no session: show #auth-gate (login/signup/forgot/reset views)
    → has session: show #app-shell + tabbar, switchTab(state.activeTab || 'online')

Supabase emits SIGNED_IN / SIGNED_OUT / PASSWORD_RECOVERY
  → handleAuthSession(session) loads profiles row and renders avatars
  → PASSWORD_RECOVERY intercepts → shows 'reset' view
```

`authUser` and `authProfile` are populated when logged in. `profiles` row is auto-created by a Postgres trigger on `auth.users` insert.

## Supabase schema (current)

- **`profiles`** : extends `auth.users` (display_name, avatar_url, currency, updated_at)
- **`games`** : owner_user_id, mode, line_price, currency, status, settings_json
- **`game_participants`** : game_id, seat_index, user_id (nullable) OR guest_name (one of)
- **`manches`** : game_id, manche_number, dealer_seat, board_results (jsonb), full_board_seat
- **`manche_results`** : manche_id, seat_index, delta, boards_won_json
- **`balances`** : user_id, other_user_id, amount, updated_at (two rows per pair, opposite signs)

RLS everywhere. SELECTs use a `public.my_game_ids()` SECURITY DEFINER helper to avoid recursion between `games` ↔ `game_participants` policies. All writes go through SECURITY DEFINER RPCs (`record_manche`, `_apply_balances_for_manche`, `_apply_transfer`).

**Storage bucket** `avatars/` : public read, owner-only write at `avatars/{user_id}/*`.

## Online flow (iOS, salle durable — 2026-09-25)

```
Hôte : createRoom → RPC room_create (code 4 chars, state = OnlineRoom seed) → transport.open(code)
Guest : joinRoom  → RPC room_join → transport.open(code)
transport.open : channel Realtime `room:CODE` (postgres_changes UPDATE = PING, jamais décodé)
                 + poll room_heartbeat (2 s lobby / 5 s partie) → room_get si version a bougé
Hôte anime : hostDriverTask = boucle de PAS IDEMPOTENTS (attente → relecture → précondition → room_publish CAS)
Guest annonce : RPC room_submit (le serveur valide siège/cartes/phase, fusionne avec les publish de l'hôte)
Bail d'hôte 15 s renouvelé par le heartbeat ; expiré → plus petit seat connecté fait room_claim_host
Présence : last_seen_at par membre ; connected = silence < 20 s ; forfait seulement après 60 s ET si le siège bloque
Quitter = geste explicite (bouton) → room_leave ; jamais implicite (onDisappear, onglet, arrière-plan)
scenePhase .active / NWPathMonitor → transport.resync()
```

Pourquoi : audit `docs/AUDIT_CONNECTIVITE_2026-09-25.md` (hôte en RAM + broadcast sans ack = accros).
Fichiers : `Core/Online/Service/RoomTransport.swift` (RPC, ping, poll, chaos, journal),
`OnlineGameService.swift` (règles + tempo + bail + présence), migration `supabase/migrations/20260925100000_online_rooms.sql`.
`room_get` **expurge** : un guest ne reçoit que sa main (`hands` à 0 ou 1 clé) et `pendingFlop/Turns/Rivers/burns = []`
hors `mancheEnd` — aucune vue guest ne doit dépendre de ces champs.

### Hooks QA (DEBUG, `Core/QA/QALaunchOptions.swift`)

`-autoLoginEmail X -autoLoginPassword Y` · `-qaRoomCode ABCD` · `-autoCreateRoom` · `-autoJoinCode ABCD` ·
`-qaBots N` (+ `-qaPassword` ou env `BAKARAT_QA_PASSWORD`) · `-autoStartAt N` · `-chaos guest-blip-10s|host-lock-30s|drop-30pct|slow-3s|double-host`.
Journal : `Documents/qa.log` (`QALog`), lisible via `xcrun simctl get_app_container <sim> com.sacha.Bakarat data`.
Comptes QA et secrets : `docs/INFRA.md`.

### Loops de test

`scripts/online-loop.sh` (launchd `com.bakarat.online-loop`, 15:00) : tests règles + protocole live (`BakaratTests`),
tour avec bots (`BakaratTourUITests`, light/dark), duel deux simulateurs (`scripts/duel.sh`), export
`audits/online/<date>/`, juge `scripts/online-judge.py` → `audits/online/OPEN.md` (registre `B-`/`C-`).

## Counter flow

- **List view** (`activeCounterId === null`) : Tricount-style list with swipe-left to delete
- **Detail view** (`activeCounterId` set) : back chevron + name in nav bar, then setup/dealer/game/manche/history sections
- Each manche validation calls `cloudRecordCounterManche()` (fire-and-forget) which calls the `record_manche` RPC
- `state.counters[].cloudGameId` is set on the first successful save and reused for subsequent manches

## UI conventions

- **iOS look** : inline navigation titles (sticky 44px translucent bar, centered 17pt 600 title, leading/trailing slots)
- **Sheets** : `.modal-overlay` slides up from the bottom, gets an auto-injected drag handle + X close button + swipe-down gesture (see `setupSheets()`)
- **Buttons** :
  - `.auth-gate-cta` : full-width red gradient pill (primary action)
  - `.big-card` : list-row-style card with icon chip + body + chevron
  - `.danger-btn` : solid systemRed (#ff3b30) — destructive actions
  - `.danger-btn.danger-soft` : 10% red tint — less aggressive (e.g., logout)
- **Inputs** : light-gray system fill (`var(--bg-soft)`), no border, radius 10-12, focus glow in Bicycle red

## Common pitfalls

- **`state.players` is the active counter's players (by reference)** : mutating `state.players[i].name = ...` directly affects `state.counters[i].players[i].name`. But `state.players = [...]` (reassignment) BREAKS the link — `save()` then re-syncs explicitly.
- **iOS : ne jamais réintroduire un `leave` implicite** (`onDisappear`, changement d'onglet) ni un `signInAnonymously` en fallback : c'étaient les accros de mai 2026. Le web (PeerJS) est legacy.
- **Supabase plan gratuit = pause après 7 jours sans requête** → `scripts/supabase-keepalive.sh` (launchd) ; vérifier `status` via l'API de gestion avant de chercher un bug réseau.
- **RLS policies that reference each other will recurse.** Always go through a SECURITY DEFINER function (like `my_game_ids()`).
- **`enable_confirmations = false`** in `supabase/config.toml` — signups create an immediate session. If you ever flip it on, the signup UX needs an "email confirmation pending" screen.
- **Service worker caches stale HTML occasionally.** When debugging UI issues, force-refresh (`Cmd+Shift+R`) before assuming the code is wrong.
- **`onclick="..."` inline handlers in template strings** reference `this.parentNode` etc. (DOM only) — no JS function calls. Don't add module-scoped function references there, they won't resolve.

## What's been built

- ✅ Auth gate : email/password, separate login + signup views, forgot/reset flow
- ✅ Tabbar : floating pill, glassmorphism, iOS-style active state
- ✅ Profile modal : avatar (upload → Supabase Storage), display_name edit, logout
- ✅ Multi-counter (Tricount-style) : list + detail + swipe-to-delete + cloud sync per counter
- ✅ Online entry redesign (skip pseudo, big create/join cards)
- ✅ PWA installable
- ✅ Persistence : games, manches, manche_results, balances (server-side trigger)

## What's next

- **Compteur detail redesign** : the inside of a counter (setup form, scoreboard, manche editor, history) still uses the old style — needs to be rewritten in the new iOS look.
- **Dettes tab** : currently a placeholder. Needs to render `manche_results` aggregated per game + the pairwise balances list.
- **Online tab polish** : the lobby + in-game views are still functional-but-ugly. Same redesign pass.
- **Capacitor wrapping** : when the UX is solid, generate `ios/` and `android/` projects, submit to stores.
- **Module migration** : the rest of `index.html` should be split into `src/auth/`, `src/online/`, `src/counter/`, etc., as patterns above. See "File map" → TODO section.

## Working on this codebase as an AI agent

1. **Read `RULES.md` first** if you're touching game logic.
2. **Read this file** to know where things live.
3. **Validate JS after each significant change** with the snippet:
   ```sh
   node -e "const fs=require('fs');const html=fs.readFileSync('index.html','utf8');const lines=html.split('\n');let s=-1,e=-1;for(let i=0;i<lines.length;i++){if(s<0 && lines[i].trim()==='<script type=\"module\">') s=i;else if(s>=0 && lines[i].trim()==='</script>') {e=i; break;}}new Function(lines.slice(s+1,e).join('\n'));console.log('JS OK')"
   ```
4. **Push to test** : `git push` triggers GitHub Pages rebuild; the user tests from the deployed URL or local server.
5. **Use Supabase CLI** for migrations — never click in the dashboard for schema changes.
6. **Match the iOS look** for any new UI : translucent nav bars, sheet modals, big-card list items, sticky titles, red gradient CTAs.
