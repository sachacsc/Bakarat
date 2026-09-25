#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Smoke-test SQL de la « salle durable » (migration 20260925100000_online_rooms.sql).

Exécute un scénario complet hôte/guest contre le Postgres de production via
l'API de gestion Supabase, en simulant `auth.uid()` :

    set local role authenticated;
    set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated"}';
    select public.room_xxx(...);

(technique vérifiée le 25/09/2026 : l'endpoint `database/query` enveloppe chaque
requête dans une transaction, donc `set local` prend bien effet et `auth.uid()`
lit `request.jwt.claims`.)

PRÉREQUIS : la migration doit être APPLIQUÉE. Sinon tout échoue en
« relation public.online_rooms does not exist ».

Usage :
    python3 scripts/sql-smoke-online-rooms.py            # exécute
    python3 scripts/sql-smoke-online-rooms.py --dry-run  # imprime le SQL, n'exécute rien
    python3 scripts/sql-smoke-online-rooms.py -v         # + payloads bruts

Sortie : une ligne PASS/FAIL par étape, exit 1 si au moins un FAIL.
Le salon de test (code QAS2) est supprimé au début ET à la fin.
"""

import argparse
import json
import os
import pathlib
import ssl
import sys
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

PROJECT_REF = "wwutjnqchxzdfxmhfaaj"
API_URL = "https://api.supabase.com/v1/projects/%s/database/query" % PROJECT_REF
ENV_FILE = os.path.expanduser("~/.zmeo-supabase.env")

# Comptes QA existants (auth.users)
HOST_UID = "10569577-513e-44d8-ae87-f9fdc76f3c4b"   # bakaratqa.host@bakarat.test
GUEST_UID = "efb1c497-a91a-4848-b0c1-a9320ca3f3b5"  # bakaratqa.g1@bakarat.test

CODE = "QAS2"          # code de salon réservé au smoke-test
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

HOST_HAND = ["As", "Kd"]    # encodage Card Swift : rang majuscule + couleur minuscule
GUEST_HAND = ["Qh", "Jc"]

# Cartes que seul l'hôte doit connaître à l'avance (expurgées pour les guests).
BURNS = ["2s", "3s", "4s"]
PENDING_FLOP = [["5c", "6d", "7h"], ["8c", "9d", "Th"], ["Jd", "Qc", "Ks"]]
PENDING_TURNS = ["2d", "3c", "4d"]
PENDING_RIVERS = ["5h", "6s", "7c"]

# Mode Flash : mains de 6 cartes, les 2 dernières (fin du tableau = dernières
# distribuées) sont publiques pour les autres sièges.
FLASH_HOST_HAND = ["Ac", "Ad", "Ah", "8s", "9s", "Ts"]
FLASH_GUEST_HAND = ["Kc", "Kh", "Ks", "2h", "3h", "4h"]


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------

def load_pat():
    """Lit SUPABASE_PAT depuis l'environnement ou ~/.zmeo-supabase.env."""
    pat = os.environ.get("SUPABASE_PAT")
    if pat:
        return pat.strip()
    path = pathlib.Path(ENV_FILE)
    if not path.exists():
        sys.exit("SUPABASE_PAT introuvable (ni dans l'env, ni dans %s)" % ENV_FILE)
    for line in path.read_text().splitlines():
        if line.startswith("SUPABASE_PAT="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("SUPABASE_PAT absent de %s" % ENV_FILE)


def ssl_context():
    """Contexte TLS ; repli sur le trousseau système si les CA Python manquent."""
    try:
        ctx = ssl.create_default_context()
        if ctx.cert_store_stats().get("x509_ca", 0) > 0:
            return ctx
    except Exception:
        pass
    for candidate in ("/etc/ssl/cert.pem", "/usr/local/etc/openssl/cert.pem"):
        if os.path.exists(candidate):
            return ssl.create_default_context(cafile=candidate)
    return ssl.create_default_context()


class Api:
    def __init__(self, pat, verbose=False):
        self.pat = pat
        self.ctx = ssl_context()
        self.verbose = verbose

    def query(self, sql):
        """Renvoie (ok: bool, payload) — payload = lignes JSON, ou texte d'erreur."""
        req = urllib.request.Request(
            API_URL,
            data=json.dumps({"query": sql}).encode("utf-8"),
            headers={"Authorization": "Bearer " + self.pat,
                     "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=60, context=self.ctx) as resp:
                body = resp.read().decode("utf-8")
                if self.verbose:
                    print("      < %s %s" % (resp.status, body[:600]))
                return True, json.loads(body) if body else []
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            if self.verbose:
                print("      < HTTP %s %s" % (exc.code, body[:600]))
            return False, body
        except Exception as exc:  # réseau, TLS, timeout…
            return False, "%s: %s" % (type(exc).__name__, exc)


# --------------------------------------------------------------------------
# Helpers SQL
# --------------------------------------------------------------------------

def dollar(text):
    """Littéral SQL dollar-quoté (le JSON ne contient jamais $j$)."""
    return "$j$%s$j$" % text


def as_user(uid, sql):
    """Enveloppe une requête dans une identité `authenticated`."""
    claims = json.dumps({"sub": uid, "role": "authenticated"})
    return ("set local role authenticated;\n"
            "set local request.jwt.claims = %s;\n"
            "%s" % (dollar(claims), sql))


def room_state(code, host_uid, participants, game=None, status="lobby", flash=False):
    """Construit un OnlineRoom encodé comme le ferait JSONEncoder côté Swift."""
    state = {
        "code": code,
        "hostUserId": host_uid,
        "participants": participants,
        "status": status,
        "linePrice": 2.5,
        "flashMode": flash,
        "announceTimerSeconds": 0,
        "pastManches": [],
    }
    if game is not None:
        state["gameState"] = game
    return state


def participant(uid, name, is_host):
    return {"userId": uid, "displayName": name, "isHost": is_host, "isOnline": True}


def game_state(submissions=None, phase="announcing", hands=None):
    """
    gameState minimal mais complet. NOTE : `hands`, `submissions`, `initialScores`
    sont des `[Int: T]` Swift — encodés par JSONEncoder comme des OBJETS à clés
    texte ({"0": …}), vérifié avec Swift 6.4. Les helpers SQL attendent ce format.
    """
    return {
        "mancheNumber": 1,
        "linePrice": 2.5,
        "players": [
            {"userId": HOST_UID, "displayName": "QA Host", "seat": 0, "score": 0.0,
             "inManche": True, "connected": True, "wantsToSpectate": False},
            {"userId": GUEST_UID, "displayName": "QA Guest", "seat": 1, "score": 0.0,
             "inManche": True, "connected": True, "wantsToSpectate": False},
        ],
        "dealerSeat": 0,
        "phase": phase,
        "currentBoard": 0,
        "rebidRound": 0,
        "hands": hands if hands is not None else {"0": HOST_HAND, "1": GUEST_HAND},
        "burns": BURNS,
        "burnsRevealed": 0,
        "communityCards": [[], [], []],
        "pendingFlop": PENDING_FLOP,
        "pendingTurns": PENDING_TURNS,
        "pendingRivers": PENDING_RIVERS,
        "submissions": submissions if submissions is not None else {},
        "boardResults": [None, None, None],
        "fullBoardWinnerSeat": None,
        "excludedThisBoard": [],
        "tiebreakBoards": [],
        "initialScores": {},
        "announceDeadline": None,
    }


PARTS_LOBBY = [participant(HOST_UID, "QA Host", True)]
PARTS_BOTH = [participant(HOST_UID, "QA Host", True),
              participant(GUEST_UID, "QA Guest", False)]


def playing_state(submissions=None):
    return room_state(CODE, HOST_UID, PARTS_BOTH,
                      game=game_state(submissions), status="playing")


def flash_state():
    return room_state(CODE, HOST_UID, PARTS_BOTH,
                      game=game_state(hands={"0": FLASH_HOST_HAND, "1": FLASH_GUEST_HAND}),
                      status="playing", flash=True)


# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

class Failure(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Failure(msg)


def one_row(payload, key="r"):
    need(isinstance(payload, list) and payload, "réponse vide : %r" % (payload,))
    need(key in payload[0], "colonne %s absente : %r" % (key, payload[0]))
    return payload[0][key]


def same_uuid(a, b):
    """Swift encode les UUID en MAJUSCULES, Postgres en minuscules."""
    return (a or "").lower() == (b or "").lower()


# --------------------------------------------------------------------------
# Scénario
# --------------------------------------------------------------------------

def build_steps(ctx):
    """
    Liste de dicts : name, sql (callable(ctx) -> str), check (callable(payload, ctx)),
    expect_error (token attendu dans le message d'erreur), bump (version en dry-run).
    """
    S = []

    def step(name, sql, check=None, expect_error=None, bump=0):
        S.append({"name": name, "sql": sql, "check": check,
                  "expect_error": expect_error, "bump": bump})

    # -- 0. remise à zéro ----------------------------------------------------
    step("reset — supprime un éventuel salon %s résiduel" % CODE,
         lambda c: "delete from public.online_rooms where code = '%s';\n"
                   "select count(*)::int as r from public.online_rooms where code = '%s';" % (CODE, CODE),
         lambda p, c: need(one_row(p) == 0, "le salon n'a pas été supprimé"))

    # -- 1. création ---------------------------------------------------------
    step("room_create — l'hôte crée %s" % CODE,
         lambda c: as_user(HOST_UID,
             "select public.room_create(p_code => '%s', p_display_name => 'QA Host', "
             "p_state => %s::jsonb) as r;"
             % (CODE, dollar(json.dumps(room_state(CODE, HOST_UID, []))))),
         check=check_create, bump=1)

    step("room_create — même code par un autre hôte => CODE_TAKEN",
         lambda c: as_user(GUEST_UID,
             "select public.room_create(p_code => '%s', p_display_name => 'QA Guest', "
             "p_state => %s::jsonb) as r;"
             % (CODE, dollar(json.dumps(room_state(CODE, GUEST_UID, []))))),
         expect_error="CODE_TAKEN")

    # -- 2. join -------------------------------------------------------------
    step("room_join — code inconnu => ROOM_NOT_FOUND",
         lambda c: as_user(GUEST_UID,
             "select public.room_join(p_code => 'ZZZZ', p_display_name => 'QA Guest') as r;"),
         expect_error="ROOM_NOT_FOUND")

    step("room_join — le guest rejoint",
         lambda c: as_user(GUEST_UID,
             "select public.room_join(p_code => '%s', p_display_name => 'QA Guest') as r;" % CODE),
         check=check_join, bump=1)

    # -- 3. lecture en lobby -------------------------------------------------
    step("room_get — le guest lit le lobby",
         lambda c: as_user(GUEST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_get_lobby)

    # -- 4. premier publish (démarrage de la manche) -------------------------
    step("room_publish — l'hôte démarre la partie (CAS ok)",
         lambda c: as_user(HOST_UID,
             "select public.room_publish(p_code => '%s', p_expected_version => %d, "
             "p_state => %s::jsonb, p_status => 'playing') as r;"
             % (CODE, c["version"], dollar(json.dumps(playing_state())))),
         check=check_publish_ok, bump=1)

    # -- 5. expurgation ------------------------------------------------------
    step("room_get — le guest ne voit QUE sa main (expurgation)",
         lambda c: as_user(GUEST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_redaction_guest)

    step("room_get — l'hôte voit toutes les mains et les 3 boards pré-tirés",
         lambda c: as_user(HOST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_redaction_host)

    step("room_get — le guest ne voit ni pendingFlop/Turns/Rivers ni burns",
         lambda c: as_user(GUEST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_redaction_pending)

    # -- 5 bis. mode Flash : cartes publiques ---------------------------------
    step("room_publish — l'hôte passe en mode Flash (mains de 6 cartes)",
         lambda c: as_user(HOST_UID,
             "select public.room_publish(p_code => '%s', p_expected_version => %d, "
             "p_state => %s::jsonb, p_status => 'playing') as r;"
             % (CODE, c["version"], dollar(json.dumps(flash_state())))),
         check=check_publish_ok, bump=1)

    step("room_get — mode Flash : le guest voit les 2 cartes publiques de l'hôte "
         "(et seulement elles), sa main entière, rien en pending",
         lambda c: as_user(GUEST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_flash_guest)

    step("room_get — mode Flash : l'hôte voit toujours les mains complètes",
         lambda c: as_user(HOST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_flash_host)

    step("room_publish — l'hôte repasse hors Flash (mains de 2 cartes)",
         lambda c: as_user(HOST_UID,
             "select public.room_publish(p_code => '%s', p_expected_version => %d, "
             "p_state => %s::jsonb, p_status => 'playing') as r;"
             % (CODE, c["version"], dollar(json.dumps(playing_state())))),
         check=check_publish_ok, bump=1)

    step("room_get — hors Flash : les autres mains sont de nouveau absentes",
         lambda c: as_user(GUEST_UID, "select public.room_get('%s') as r;" % CODE),
         check=check_redaction_guest)

    # -- 6. CAS --------------------------------------------------------------
    step("room_publish — mauvaise version => conflict, aucune écriture",
         lambda c: as_user(HOST_UID,
             "select public.room_publish(p_code => '%s', p_expected_version => 1, "
             "p_state => %s::jsonb, p_status => 'playing') as r;"
             % (CODE, dollar(json.dumps(playing_state())))),
         check=check_conflict)

    # -- 7. annonces ---------------------------------------------------------
    step("room_submit — siège d'un autre => NOT_YOUR_SEAT",
         lambda c: as_user(GUEST_UID,
             "select public.room_submit('%s', 0, %s::jsonb) as r;"
             % (CODE, dollar(json.dumps({"categoryId": "pair", "cards": HOST_HAND})))),
         expect_error="NOT_YOUR_SEAT")

    step("room_submit — cartes hors de la main => BAD_CARDS",
         lambda c: as_user(GUEST_UID,
             "select public.room_submit('%s', 1, %s::jsonb) as r;"
             % (CODE, dollar(json.dumps({"categoryId": "pair", "cards": ["As", "Kd"]})))),
         expect_error="BAD_CARDS")

    step("room_submit — le guest annonce (siège 1)",
         lambda c: as_user(GUEST_UID,
             "select public.room_submit('%s', 1, %s::jsonb) as r;"
             % (CODE, dollar(json.dumps({"categoryId": "pair", "cards": GUEST_HAND})))),
         check=check_submit, bump=1)

    step("room_submit — deuxième fois => ALREADY_SUBMITTED",
         lambda c: as_user(GUEST_UID,
             "select public.room_submit('%s', 1, %s::jsonb) as r;"
             % (CODE, dollar(json.dumps({"categoryId": "pair", "cards": GUEST_HAND})))),
         expect_error="ALREADY_SUBMITTED")

    # -- 8. fusion des annonces ---------------------------------------------
    step("room_publish — l'hôte republie SANS l'annonce => elle est préservée",
         lambda c: as_user(HOST_UID,
             "select public.room_publish(p_code => '%s', p_expected_version => %d, "
             "p_state => %s::jsonb, p_status => 'playing') as r;"
             % (CODE, c["version"], dollar(json.dumps(playing_state(submissions={}))))),
         check=check_merge, bump=1)

    # -- 9. bail d'hôte ------------------------------------------------------
    step("room_claim_host — bail encore actif => LEASE_ACTIVE",
         lambda c: as_user(GUEST_UID, "select public.room_claim_host('%s') as r;" % CODE),
         expect_error="LEASE_ACTIVE")

    step("bail expiré à la main (UPDATE direct, hors RPC)",
         lambda c: "update public.online_rooms set host_lease_until = now() - interval '1 minute' "
                   "where code = '%s';\n"
                   "select (host_lease_until < now()) as r from public.online_rooms "
                   "where code = '%s';" % (CODE, CODE),
         lambda p, c: need(one_row(p) is True, "le bail n'est pas expiré"))

    step("room_claim_host — bail expiré => le guest devient hôte",
         lambda c: as_user(GUEST_UID, "select public.room_claim_host('%s') as r;" % CODE),
         check=check_claim_ok, bump=1)

    step("room_publish — l'ex-hôte est refusé => NOT_HOST",
         lambda c: as_user(HOST_UID,
             "select public.room_publish(p_code => '%s', p_expected_version => %d, "
             "p_state => %s::jsonb, p_status => 'playing') as r;"
             % (CODE, c["version"], dollar(json.dumps(playing_state())))),
         expect_error="NOT_HOST")

    step("room_heartbeat — retour léger du nouvel hôte",
         lambda c: as_user(GUEST_UID, "select public.room_heartbeat('%s') as r;" % CODE),
         check=check_heartbeat)

    # -- 10. départs ---------------------------------------------------------
    step("room_leave — le guest (hôte courant) quitte",
         lambda c: as_user(GUEST_UID, "select public.room_leave('%s') as r;" % CODE),
         check=check_leave_host, bump=1)

    step("room_get — un partant n'est plus membre => NOT_MEMBER",
         lambda c: as_user(GUEST_UID, "select public.room_get('%s') as r;" % CODE),
         expect_error="NOT_MEMBER")

    step("room_leave — l'hôte d'origine quitte aussi",
         lambda c: as_user(HOST_UID, "select public.room_leave('%s') as r;" % CODE),
         check=lambda p, c: need(one_row(p).get("left") is True, "left != true"), bump=1)

    # -- 11. code aléatoire --------------------------------------------------
    step("room_create — sans code => 4 caractères de l'alphabet lisible",
         lambda c: as_user(HOST_UID,
             "select public.room_create(p_display_name => 'QA Host', p_state => %s::jsonb) as r;"
             % dollar(json.dumps(room_state("", HOST_UID, [])))),
         check=check_random_code)

    # -- 12. purge / nettoyage ----------------------------------------------
    # La purge est exercée pour de vrai mais dans une transaction annulée :
    # on vérifie qu'elle supprime bien le salon marqué `finished` sans toucher
    # durablement aux salons des vrais joueurs. (Si l'API de gestion refusait le
    # contrôle de transaction explicite, cette étape est la seule à sauter.)
    step("purge_stale_online_rooms — supprime un salon 'finished' (transaction annulée)",
         lambda c: "begin;\n"
                   "update public.online_rooms set status = 'finished' where code = '%s';\n"
                   "select public.purge_stale_online_rooms() as r;\n"
                   "rollback;" % c.get("random_code", "____"),
         lambda p, c: need(isinstance(one_row(p), int) and one_row(p) >= 1,
                           "la purge n'a supprimé aucune ligne"))

    step("nettoyage final",
         lambda c: "delete from public.online_rooms where code in ('%s', '%s');\n"
                   "select count(*)::int as r from public.online_rooms "
                   "where code in ('%s', '%s');"
                   % (CODE, c.get("random_code", "____"), CODE, c.get("random_code", "____")),
         lambda p, c: need(one_row(p) == 0, "salons de test encore présents"))

    return S


# --------------------------------------------------------------------------
# Vérifications par étape
# --------------------------------------------------------------------------

def check_create(payload, ctx):
    r = one_row(payload)
    need(r["code"] == CODE, "code inattendu : %r" % r["code"])
    need(r["version"] == 1, "version attendue 1, reçue %r" % r["version"])
    need(r["status"] == "lobby", "status attendu lobby, reçu %r" % r["status"])
    need(same_uuid(r["host_user_id"], HOST_UID), "host_user_id inattendu")
    need(r["state"]["code"] == CODE, "state.code non forcé par le serveur")
    need(same_uuid(r["state"]["hostUserId"], HOST_UID), "state.hostUserId non forcé")
    need(len(r["state"]["participants"]) == 1, "l'hôte doit être seul participant")
    need(r["state"]["participants"][0]["isHost"] is True, "isHost != true")
    need(len(r["members"]) == 1, "1 membre attendu")
    need(r["server_now"].endswith("Z"), "server_now n'est pas en ISO-8601 UTC")
    ctx["version"] = r["version"]


def check_join(payload, ctx):
    r = one_row(payload)
    need(r["version"] == ctx["version"] + 1, "version non incrémentée")
    ids = [p["userId"].lower() for p in r["state"]["participants"]]
    need(GUEST_UID in ids, "le guest n'est pas dans state.participants")
    need(len(r["members"]) == 2, "2 membres attendus, %d reçus" % len(r["members"]))
    ctx["version"] = r["version"]


def check_get_lobby(payload, ctx):
    r = one_row(payload)
    need(r["code"] == CODE, "code inattendu")
    need(r["version"] == ctx["version"], "version instable sur une lecture")
    need(r["state"].get("gameState") in (None,), "gameState devrait être absent en lobby")


def check_publish_ok(payload, ctx):
    r = one_row(payload)
    need(r["conflict"] is False, "conflict attendu false")
    room = r["room"]
    need(room["version"] == ctx["version"] + 1, "version non incrémentée")
    need(room["status"] == "playing", "status attendu playing")
    need(room["host_lease_until"] > room["server_now"], "le bail n'a pas été renouvelé")
    ctx["version"] = room["version"]


def check_redaction_guest(payload, ctx):
    r = one_row(payload)
    hands = r["state"]["gameState"]["hands"]
    need("1" in hands, "le guest ne voit pas sa propre main")
    need(hands["1"] == GUEST_HAND, "main du guest altérée : %r" % hands["1"])
    need("0" not in hands, "FUITE : le guest voit la main de l'hôte")
    need(len(hands) == 1, "hands devrait contenir exactement 1 entrée")


def check_redaction_host(payload, ctx):
    r = one_row(payload)
    gs = r["state"]["gameState"]
    need("0" in gs["hands"] and "1" in gs["hands"], "l'hôte doit voir toutes les mains")
    need(len(gs["pendingFlop"]) == 3,
         "l'hôte doit voir les 3 boards pré-tirés, reçu %r" % gs["pendingFlop"])
    need(gs["pendingTurns"] == PENDING_TURNS, "pendingTurns altéré pour l'hôte")
    need(gs["pendingRivers"] == PENDING_RIVERS, "pendingRivers altéré pour l'hôte")
    need(gs["burns"] == BURNS, "burns altéré pour l'hôte")


def check_redaction_pending(payload, ctx):
    """Le guest ne doit rien savoir des cartes à venir ni des brûlées."""
    r = one_row(payload)
    gs = r["state"]["gameState"]
    need(gs["pendingFlop"] == [], "FUITE : le guest voit pendingFlop %r" % gs["pendingFlop"])
    need(gs["pendingTurns"] == [], "FUITE : le guest voit pendingTurns")
    need(gs["pendingRivers"] == [], "FUITE : le guest voit pendingRivers")
    need(gs["burns"] == [], "FUITE : le guest voit les cartes brûlées")
    need(gs["burnsRevealed"] == 0, "burnsRevealed doit rester lisible")
    need(gs["communityCards"] == [[], [], []], "communityCards ne doit pas être expurgé")


def check_flash_guest(payload, ctx):
    """Flash : main complète pour soi, 2 dernières cartes des autres, pas de pending."""
    r = one_row(payload)
    gs = r["state"]["gameState"]
    need(r["state"].get("flashMode") is True, "flashMode perdu dans le state lu")
    hands = gs["hands"]
    need(hands.get("1") == FLASH_GUEST_HAND,
         "le guest doit voir sa main entière, reçu %r" % hands.get("1"))
    need("0" in hands, "Flash : le guest ne voit pas les cartes publiques de l'hôte")
    need(hands["0"] == FLASH_HOST_HAND[-2:],
         "Flash : attendu les 2 dernières cartes de l'hôte %r, reçu %r"
         % (FLASH_HOST_HAND[-2:], hands["0"]))
    need(len(hands) == 2, "hands devrait contenir exactement 2 entrées : %r" % hands)
    for k in ("pendingFlop", "pendingTurns", "pendingRivers", "burns"):
        need(gs[k] == [], "FUITE : le guest voit %s en mode Flash" % k)


def check_flash_host(payload, ctx):
    r = one_row(payload)
    hands = r["state"]["gameState"]["hands"]
    need(hands.get("0") == FLASH_HOST_HAND and hands.get("1") == FLASH_GUEST_HAND,
         "l'hôte doit voir les mains complètes en Flash, reçu %r" % hands)


def check_conflict(payload, ctx):
    r = one_row(payload)
    need(r["conflict"] is True, "conflict attendu true")
    need(r["room"]["version"] == ctx["version"], "la version a bougé malgré le conflit")


def check_submit(payload, ctx):
    r = one_row(payload)
    need(r["version"] == ctx["version"] + 1, "version non incrémentée")
    subs = r["state"]["gameState"]["submissions"]
    need("1" in subs, "annonce absente de submissions")
    need(subs["1"]["categoryId"] == "pair", "categoryId altéré")
    ctx["version"] = r["version"]


def check_merge(payload, ctx):
    r = one_row(payload)
    need(r["conflict"] is False, "conflict attendu false")
    room = r["room"]
    need(room["version"] == ctx["version"] + 1, "version non incrémentée")
    subs = room["state"]["gameState"]["submissions"]
    need("1" in subs, "FUSION KO : l'hôte a effacé l'annonce du guest")
    need(subs["1"]["cards"] == GUEST_HAND, "annonce fusionnée altérée")
    ctx["version"] = room["version"]


def check_claim_ok(payload, ctx):
    r = one_row(payload)
    need(same_uuid(r["host_user_id"], GUEST_UID), "host_user_id non transféré")
    need(same_uuid(r["state"]["hostUserId"], GUEST_UID), "state.hostUserId non transféré")
    need(r["host_lease_until"] > r["server_now"], "bail non renouvelé")
    need(r["version"] == ctx["version"] + 1, "version non incrémentée")
    for p in r["state"]["participants"]:
        expected = same_uuid(p["userId"], GUEST_UID)
        need(p["isHost"] is expected, "participants[].isHost non recalculé")
    ctx["version"] = r["version"]


def check_heartbeat(payload, ctx):
    r = one_row(payload)
    for key in ("version", "host_user_id", "host_lease_until", "server_now", "members"):
        need(key in r, "clé %s absente du heartbeat" % key)
    need("state" not in r, "le heartbeat doit rester léger (pas de state)")
    need(r["version"] == ctx["version"], "le heartbeat ne doit pas incrémenter la version")


def check_leave_host(payload, ctx):
    r = one_row(payload)
    need(r["left"] is True, "left != true")
    need(r["host_lease_until"] <= r["server_now"],
         "le bail de l'hôte partant doit être expiré")
    need(r["version"] == ctx["version"] + 1, "version non incrémentée")
    ctx["version"] = r["version"]


def check_random_code(payload, ctx):
    r = one_row(payload)
    code = r["code"]
    need(len(code) == 4, "code aléatoire de %d caractères" % len(code))
    need(all(ch in ALPHABET for ch in code), "code hors alphabet : %r" % code)
    need(code != CODE, "collision improbable avec le code de test")
    ctx["random_code"] = code


# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true",
                        help="imprime le SQL de chaque étape sans rien exécuter")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="affiche les payloads bruts")
    args = parser.parse_args()

    ctx = {"version": 0, "random_code": "____"}
    steps = build_steps(ctx)

    if args.dry_run:
        print("=== DRY RUN — %d étapes, aucune requête envoyée ===\n" % len(steps))
        for i, st in enumerate(steps, 1):
            tag = "  [erreur attendue : %s]" % st["expect_error"] if st["expect_error"] else ""
            print("--- %02d. %s%s" % (i, st["name"], tag))
            print(st["sql"](ctx))
            print()
            ctx["version"] += st["bump"]
        print("=== dry run terminé (versions simulées, résultats non vérifiés) ===")
        return 0

    api = Api(load_pat(), verbose=args.verbose)
    failures = 0
    print("=== Smoke online_rooms — projet %s ===\n" % PROJECT_REF)

    for i, st in enumerate(steps, 1):
        sql = st["sql"](ctx)
        ok, payload = api.query(sql)
        label = "%02d. %s" % (i, st["name"])
        try:
            if st["expect_error"]:
                need(not ok, "la requête a réussi alors que %s était attendu" % st["expect_error"])
                need(st["expect_error"] in str(payload),
                     "message attendu %s, reçu : %s" % (st["expect_error"], str(payload)[:200]))
            else:
                need(ok, "requête en échec : %s" % str(payload)[:300])
                if st["check"]:
                    st["check"](payload, ctx)
            print("PASS  %s" % label)
        except Failure as exc:
            failures += 1
            print("FAIL  %s\n        -> %s" % (label, exc))
        except Exception as exc:  # payload inattendu
            failures += 1
            print("FAIL  %s\n        -> %s: %s" % (label, type(exc).__name__, exc))

    print("\n=== %d étape(s) en échec sur %d ===" % (failures, len(steps)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
