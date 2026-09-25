#!/usr/bin/env python3
"""Le juge Online — les yeux de l'owner sur la loop Online v2 (T36, port de
`ui-tour-judge.py`, 2026-09-25).

La loop (`online-loop.sh`) photographie et mesure, elle ne juge pas. Ce script
fait juger les captures + `summary.json` d'un run par `claude -p` (abonnement
Claude Code du Mac — **jamais la clé API**) avec le prompt
`scripts/online-judge-prompt.md`, tient le registre vivant des findings
(`audits/online/registry.json` → rendu `OPEN.md`), écrit le rapport du jour
`audits/online/<date>.md`, et publie les trois via l'API Contents de GitHub
(dépôt `sachacsc/Bakarat`) — jamais le working tree de l'owner.

Deux préfixes d'id : `B-xxxx` (usage/connectivité — lisibilité, lenteur,
bannière confuse) et `C-xxxx` (scénarios chaos qui échouent — un test
`failed` ou une capture `*-FAIL-*`/`*-DIAG-*` dans `summary.json` est une
panne, P1 d'office).

Cycle de vie d'un finding : `open` (vu) → `still` à chaque run où il est encore
visible → `gone` quand le juge ne le reproduit plus → `fixed` après DEUX runs
consécutifs `gone` (un seul run muet peut être un scénario qui n'a pas joué).

Usage : scripts/online-judge.py <run_dir> [--model sonnet] [--dry-run] [--from-transcript]
"""
import base64
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timezone
from pathlib import Path

REPO_SLUG = "sachacsc/Bakarat"
REPO = Path(__file__).resolve().parent.parent
RAIL = "audits/online"
PROMPT = REPO / "scripts/online-judge-prompt.md"
MAX_SHOTS = 72


def log(msg):
    print(f"[online-judge] {msg}", flush=True)


# ── GitHub Contents : lire / publier sans toucher au working tree ─────────────

def gh_read(path):
    r = subprocess.run(["gh", "api", f"repos/{REPO_SLUG}/contents/{path}", "--jq", ".content"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return base64.b64decode(r.stdout.strip()).decode()


def gh_publish(path, content, message):
    sha = subprocess.run(["gh", "api", f"repos/{REPO_SLUG}/contents/{path}", "--jq", ".sha"],
                         capture_output=True, text=True, timeout=60).stdout.strip()
    args = ["gh", "api", "--method", "PUT", f"repos/{REPO_SLUG}/contents/{path}",
            "-f", f"message={message}",
            "-f", f"content={base64.b64encode(content.encode()).decode()}",
            "-f", "branch=main"]
    if sha:
        args += ["-f", f"sha={sha}"]
    subprocess.run(args, check=True, capture_output=True, timeout=120)


# ── Les captures qui comptent ────────────────────────────────────────────────

def select_shots(run_dir):
    shots = sorted((run_dir / "shots").glob("*.png"))
    diag = [s for s in shots if "DIAG" in s.name or "FAIL" in s.name]
    rest = [s for s in shots
            if s.name.startswith(("tour-light-", "duel-host-", "duel-guest-"))
            and s not in diag]
    picked = diag + rest
    return picked[:MAX_SHOTS]


def load_summary(run_dir):
    p = run_dir / "summary.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return None


# ── Le registre ──────────────────────────────────────────────────────────────

def load_registry():
    raw = gh_read(f"{RAIL}/registry.json")
    if raw:
        return json.loads(raw)
    local = REPO / RAIL / "registry.json"
    if local.exists():
        return json.loads(local.read_text())
    return {"next_id": 1, "next_chaos_id": 1, "items": []}


def render_open(reg, today):
    live = [i for i in reg["items"] if i["status"] in ("open", "still", "gone")]
    fixed = [i for i in reg["items"] if i["status"] == "fixed"]
    L = ["# Findings Online v2 — registre vivant", "",
         "> Écrit par `scripts/online-judge.py` après chaque loop Online v2 (15 h Paris,",
         "> après le tour Zmeo de 13 h). Ce sont les **yeux du joueur** : ce qu'un joueur",
         "> exigeant voit sur les captures du tour et du duel. `B-xxxx` = usage/connectivité,",
         "> `C-xxxx` = scénario chaos en échec (test `failed` ou capture `*-FAIL-*`/`*-DIAG-*`),",
         "> P1 d'office. Une loop de correction lit ce fichier et ajoute l'assertion XCUITest",
         "> qui l'aurait vu ; le juge le passe `gone` puis `fixed` quand il ne le reproduit plus.",
         "", f"_Dernier passage : {today}._", "",
         "## Ouverts", ""]
    order = {"P1": 0, "P2": 1, "P3": 2}
    for i in sorted(live, key=lambda x: (order.get(x["prio"], 9), x["id"])):
        if i["status"] == "gone":
            state = f"gone depuis {i.get('last_gone')} (à confirmer au prochain run)"
        elif i["status"] == "still":
            state = f"open — vu ×{i['seen']} depuis {i['first_seen']}"
        else:
            state = "open"
        tag = " [chaos]" if i.get("kind") == "chaos" else ""
        L.append(f"- **{i['id']}** [{i['prio']}]{tag} {i['title']} — écran/suite : `{i['screen']}` — "
                 f"élément : {i['element']} — attendu : {i['expected']} — {state}"
                 + (f" — in-progress: {i['pr']}" if i.get("pr") else ""))
    if not live:
        L.append("_Aucun — la loop n'a rien trouvé à redire._")
    L += ["", "## Fermés (fix vérifié par la loop)", ""]
    for i in sorted(fixed, key=lambda x: x["id"], reverse=True)[:40]:
        L.append(f"- ~~{i['id']}~~ [{i['prio']}] {i['title']} — fixé le {i['fixed_on']}"
                 + (f" ({i['pr']})" if i.get("pr") else ""))
    return "\n".join(L) + "\n"


def render_daily(run_dir, today, new_items, still, gone, fixed_now, shots, summary):
    L = [f"# Juge Online v2 — {today}", "",
         f"Run : `{run_dir.name}` · {len(shots)} captures relues · "
         f"{len(new_items)} nouveaux · {len(still)} toujours visibles · "
         f"{len(gone)} plus reproduits · {len(fixed_now)} fermés", ""]
    if summary:
        fails = [(name, s) for name, s in summary.get("suites", {}).items() if s.get("failed")]
        L.append(f"Suites : {len(summary.get('suites', {}))} · échecs : "
                 f"{', '.join(n for n, _ in fails) or 'aucun'} · "
                 f"captures FAIL/DIAG : {len(summary.get('diag_or_fail_shots', []))}")
        L.append("")
    if new_items:
        L += ["## Nouveaux", ""]
        for i in new_items:
            L.append(f"- **{i['id']}** [{i['prio']}] {i['title']} — écran/suite : `{i['screen']}` — "
                     f"élément : {i['element']} — attendu : {i['expected']}")
        L.append("")
    if fixed_now:
        L += ["## Fermés aujourd'hui (deux runs sans le reproduire)", ""]
        L += [f"- {i['id']} {i['title']}" for i in fixed_now] + [""]
    if gone:
        L += ["## Plus reproduits (à confirmer demain)", ""]
        L += [f"- {i['id']} {i['title']}" for i in gone] + [""]
    if still:
        L += ["## Toujours visibles", ""]
        L += [f"- {i['id']} [{i['prio']}] {i['title']}" for i in still] + [""]
    L += ["---", "Captures : dossier local du run (non versionné). Registre : `OPEN.md`."]
    return "\n".join(L) + "\n"


# ── Le juge ──────────────────────────────────────────────────────────────────

def ask_judge(shots, reg, summary, model):
    live = [i for i in reg["items"] if i["status"] in ("open", "still", "gone")]
    registry_lines = "\n".join(
        f"- {i['id']} [{i['prio']}] {i['title']} — écran/suite {i['screen']} — élément : {i['element']}"
        for i in live) or "(registre vide)"
    shot_lines = "\n".join(f"- {s}" for s in shots)
    summary_json = json.dumps(summary, ensure_ascii=False, indent=2) if summary else "(summary.json absent)"
    prompt = (PROMPT.read_text()
              + "\n\n## Les captures de ce run (dans l'ordre des étapes — lis-les TOUTES avec Read)\n\n"
              + shot_lines
              + "\n\n## summary.json de ce run (suites, échecs, heuristiques)\n\n```json\n"
              + summary_json + "\n```\n"
              + "\n\n## Le registre en cours (rends un verdict still/gone pour CHAQUE id)\n\n"
              + registry_lines + "\n")
    r = subprocess.run(["claude", "-p", prompt, "--allowedTools", "Read",
                        "--model", model, "--output-format", "text"],
                       capture_output=True, text=True, timeout=1800,
                       env={k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"})
    if r.returncode != 0:
        raise RuntimeError(f"claude -p a échoué : {r.stderr[-500:]}")
    m = re.search(r"```json\s*(\{.*?\})\s*```", r.stdout, re.S)
    if not m:
        raise RuntimeError(f"pas de bloc JSON dans la réponse :\n{r.stdout[-800:]}")
    return json.loads(m.group(1)), r.stdout


def main():
    if "--help" in sys.argv[1:] or "-h" in sys.argv[1:] or len(sys.argv) < 2:
        sys.exit(__doc__)
    run_dir = Path(sys.argv[1]).resolve()
    model = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else "sonnet"
    dry = "--dry-run" in sys.argv
    today = date.today().isoformat()

    shots = select_shots(run_dir)
    summary = load_summary(run_dir)
    if not shots and not summary:
        sys.exit("aucune capture ni summary.json à juger")
    log(f"{len(shots)} captures → juge ({model})")

    reg = load_registry()
    reg.setdefault("next_chaos_id", 1)
    transcript_path = run_dir / "judge-transcript.md"
    if "--from-transcript" in sys.argv and transcript_path.exists():
        transcript = transcript_path.read_text()
        verdict = json.loads(re.search(r"```json\s*(\{.*?\})\s*```", transcript, re.S).group(1))
    else:
        verdict, transcript = ask_judge(shots, reg, summary, model)
        transcript_path.write_text(transcript)

    by_id = {i["id"]: i for i in reg["items"]}
    still, gone, fixed_now = [], [], []
    for v in verdict.get("verdicts", []):
        item = by_id.get(v.get("id"))
        if not item or item["status"] == "fixed":
            continue
        if v.get("state") == "still":
            item.update(status="still", seen=item.get("seen", 1) + 1, last_seen=today, gone_streak=0)
            still.append(item)
        elif v.get("state") == "gone":
            streak = item.get("gone_streak", 0) + 1
            if streak >= 2:
                item.update(status="fixed", fixed_on=today, gone_streak=streak)
                fixed_now.append(item)
            else:
                item.update(status="gone", last_gone=today, gone_streak=streak)
                gone.append(item)

    new_items = []
    for f in verdict.get("findings", [])[:10]:
        if not all(k in f for k in ("prio", "screen", "element", "title", "expected")):
            continue
        # T36 : un finding de chaos (scénario T24/T34 en échec) porte le préfixe
        # C- et son propre compteur, P1 d'office (règle appliquée par le prompt).
        chaos = f.get("kind") == "C"
        counter = "next_chaos_id" if chaos else "next_id"
        item = {"id": f"{'C' if chaos else 'B'}-{reg[counter]:04d}", "prio": f["prio"], "screen": f["screen"],
                "element": f["element"], "title": f["title"], "expected": f["expected"],
                "status": "open", "seen": 1, "first_seen": today, "last_seen": today,
                "gone_streak": 0, "kind": "chaos" if chaos else "usage"}
        reg[counter] += 1
        reg["items"].append(item)
        new_items.append(item)

    daily = render_daily(run_dir, today, new_items, still, gone, fixed_now, shots, summary)
    open_md = render_open(reg, today)
    registry = json.dumps(reg, ensure_ascii=False, indent=2) + "\n"
    log(f"{len(new_items)} nouveaux · {len(still)} still · {len(gone)} gone · {len(fixed_now)} fixés")

    if dry:
        print(daily)
        print(open_md)
        return
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    gh_publish(f"{RAIL}/{today}.md", daily, f"chore(online): juge {stamp} UTC — rapport")
    gh_publish(f"{RAIL}/registry.json", registry, f"chore(online): juge {stamp} UTC — registre")
    gh_publish(f"{RAIL}/OPEN.md", open_md, f"chore(online): juge {stamp} UTC — OPEN")
    log(f"publié → {RAIL}/{today}.md + OPEN.md")


if __name__ == "__main__":
    main()
