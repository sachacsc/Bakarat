#!/bin/bash
# La loop Online v2 — la boucle de test automatisée (T35, port Zmeo ui-tour.sh,
# 2026-09-25). Build une fois, joue les unitaires, le tour (clair/sombre) sur
# un simulateur, le duel sur deux simulateurs en parallèle, exporte captures +
# logs + summary.json, puis appelle le juge. Ce script photographie, il ne
# juge pas — la relecture visuelle est online-judge.py (T36).
#
# Usage : scripts/online-loop.sh [--skip-build] [--only tour|duel|unit] [--no-judge]
set -euo pipefail
# launchd n'a qu'un PATH minimal : claude (juge) et gh (publication) vivent ici
# (même piège que Zmeo — cf scripts/launchd/com.zmeo.ui-tour.plist).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Bakarat/Bakarat.xcodeproj"
SCHEME="Bakarat"
DATE="$(date +%Y-%m-%d-%H%M)"
OUT="$REPO/audits/online/$DATE"
# JAMAIS dans /tmp : macOS purge les fichiers inactifs et ampute la DerivedData
# en silence (leçon Zmeo — plusieurs runs à zéro pour cette raison).
DERIVED="$HOME/Library/Caches/bakarat-loop-dd"
mkdir -p "$OUT"

log() { echo "[online-loop] $*"; }

# ── Options ──────────────────────────────────────────────────────────────────
SKIP_BUILD=0
ONLY=""
NO_JUDGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --only) ONLY="$2"; shift ;;
    --no-judge) NO_JUDGE=1 ;;
    *) log "option inconnue : $1" ;;
  esac
  shift
done
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ── Secrets QA (mot de passe des comptes bakaratqa.*@bakarat.test) ─────────────
QA_ENV="$HOME/.bakarat-qa.env"
if [ -f "$QA_ENV" ]; then
  set -a; source "$QA_ENV"; set +a
else
  log "ATTENTION : $QA_ENV absent — les tests d'auto-login échoueront"
fi

# ── Les deux simulateurs dédiés ──────────────────────────────────────────────
# Retrouvés par nom ; recréés si absents (même logique que ui-tour.sh — sim
# figé au nom "bakarat-host"/"bakarat-guest", jamais le sim booté par défaut).
DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"

find_or_create_sim() {
  local name="$1"
  local id
  id=$(xcrun simctl list devices | grep "$name (" | grep -oE "[0-9A-F-]{36}" | head -1 || true)
  if [ -z "$id" ]; then
    local runtime
    runtime=$(xcrun simctl list runtimes | grep -oE "com.apple.CoreSimulator.SimRuntime.iOS-26-5" | tail -1)
    id=$(xcrun simctl create "$name" "$DEVTYPE" "$runtime")
    log "sim créé : $name → $id"
  fi
  echo "$id"
}

HOST_ID=$(find_or_create_sim "bakarat-host")
GUEST_ID=$(find_or_create_sim "bakarat-guest")
log "bakarat-host  = $HOST_ID"
log "bakarat-guest = $GUEST_ID"
# UN SEUL simulateur booté à la fois hors duel : deux sims + diskimagesiod
# saturent le Mac (load > 40, runners XCUITest « timed out while preparing »,
# vécu le 2026-09-25). Le guest n'est booté que pour le duel, puis éteint.
xcrun simctl shutdown "$GUEST_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$HOST_ID" -b >/dev/null 2>&1 || true
sleep 20   # laisse SpringBoard finir de démarrer avant le premier runner

# ── Journal QA de l'app (Documents/qa.log) ───────────────────────────────────
# Un XCUITest ne peut pas lire le container de l'app : c'est le runner qui va
# le chercher. `QALog` (Core/QA/QALaunchOptions.swift) n'écrit que si un hook
# QA est actif — donc uniquement pendant le tour et le duel. Bonus : ce fichier
# atterrit dans $OUT/*.log, que les heuristiques de summary.json parcourent
# déjà (resync / room_claim_host / conflict y apparaissent tels quels).
export_qa_log() {
  local sim="$1" dest="$2"
  local container
  container=$(xcrun simctl get_app_container "$sim" com.sacha.Bakarat data 2>/dev/null || true)
  if [ -z "$container" ] || [ ! -f "$container/Documents/qa.log" ]; then
    log "qa.log introuvable pour $sim (app jamais lancée avec un hook QA ?)"
    return 0
  fi
  cp "$container/Documents/qa.log" "$dest"
  log "qa.log → $(basename "$dest") ($(wc -l < "$dest" | tr -d ' ') lignes)"
  # On repart d'un journal vide : la passe suivante ne doit pas relire celle
  # d'avant (sinon les compteurs de summary.json doublent).
  : > "$container/Documents/qa.log"
}

# ── Auto-guérison SPM (leçon Zmeo — un kill pendant un download laisse un
# artefact corrompu et TOUTES les passes échouent en silence) ────────────────
heal_spm_if_needed() {
  local logfile="$1"
  if grep -qE "no (Info.plist|XCFramework) found" "$logfile"; then
    log "artefact SPM corrompu détecté → purge + resolve"
    rm -rf "$DERIVED/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" \
      -scheme "$SCHEME" -derivedDataPath "$DERIVED" >/dev/null 2>&1 || true
    return 0
  fi
  if grep -q "module file not found" "$logfile"; then
    log "cache de modules incohérent détecté → purge des intermédiaires"
    rm -rf "$DERIVED/Build/Intermediates.noindex" "$DERIVED/ModuleCache.noindex"
    return 0
  fi
  return 1
}

# ── (a) build-for-testing, une fois, sur bakarat-host ────────────────────────
if [ "$SKIP_BUILD" -eq 0 ]; then
  log "build-for-testing (bakarat-host)"
  BUILD_LOG="$OUT/build.log"
  xcodebuild build-for-testing \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$HOST_ID" \
    -derivedDataPath "$DERIVED" \
    -parallel-testing-enabled NO \
    2>&1 | tee "$BUILD_LOG" | grep -E "BUILD (SUCCEEDED|FAILED)|error:" || true
  if grep -q "BUILD FAILED" "$BUILD_LOG"; then
    if heal_spm_if_needed "$BUILD_LOG"; then
      log "rejoue le build après guérison"
      xcodebuild build-for-testing \
        -project "$PROJECT" -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$HOST_ID" \
        -derivedDataPath "$DERIVED" \
        -parallel-testing-enabled NO \
        2>&1 | tee "$BUILD_LOG" | grep -E "BUILD (SUCCEEDED|FAILED)|error:" || true
    fi
  fi
  if grep -q "BUILD FAILED" "$BUILD_LOG"; then
    log "build KO — abandon (voir $BUILD_LOG)"
    exit 1
  fi
else
  log "--skip-build : on suppose une build-for-testing existante dans $DERIVED"
fi

# ── Le lanceur de suite générique (test-without-building + guérison + retry) ─
# run_suite <sim_id> <tests xcodebuild args...> -- <bundle_name> [env=VAL ...]
run_suite() {
  local sim_id="$1" bundle="$2"; shift 2
  local tests=("$@")
  local logfile="$OUT/$bundle.log"
  log "passe $bundle (sim $sim_id)"
  xcodebuild test-without-building \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$sim_id" \
    -derivedDataPath "$DERIVED" \
    -parallel-testing-enabled NO \
    "${tests[@]}" \
    -resultBundlePath "$OUT/$bundle.xcresult" \
    2>&1 | tee "$logfile" | grep -E "Test Case.*(passed|failed)|\*\* TEST" || true
  if heal_spm_if_needed "$logfile"; then
    log "rejoue $bundle après guérison"
    rm -rf "$OUT/$bundle.xcresult"
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$sim_id" \
      -derivedDataPath "$DERIVED" \
      -parallel-testing-enabled NO \
      "${tests[@]}" \
      -resultBundlePath "$OUT/$bundle.xcresult" \
      2>&1 | tee "$logfile" | grep -E "Test Case.*(passed|failed)|\*\* TEST" || true
  fi
}

# ── (b) Unitaires BakaratTests, avec les live tests protocole (T31) ──────────
# TEST_RUNNER_BAKARAT_LIVE_TESTS=1 traverse xcodebuild → process de test →
# BAKARAT_LIVE_TESTS côté Swift (convention Xcode : préfixe TEST_RUNNER_ retiré
# à l'arrivée dans l'environnement du test host).
if want unit; then
  TEST_RUNNER_BAKARAT_LIVE_TESTS=1 \
  TEST_RUNNER_BAKARAT_QA_PASSWORD="${BAKARAT_QA_PASSWORD:-}" \
    run_suite "$HOST_ID" "unit" -only-testing:BakaratTests
fi

# ── (c) Le tour, clair puis sombre, sur bakarat-host ─────────────────────────
if want tour; then
  for mode in light dark; do
    xcrun simctl ui "$HOST_ID" appearance "$mode" || true
    TEST_RUNNER_TOUR_MODE="$mode" \
    TEST_RUNNER_BAKARAT_QA_PASSWORD="${BAKARAT_QA_PASSWORD:-}" \
      run_suite "$HOST_ID" "tour-$mode" -only-testing:BakaratUITests/BakaratTourUITests
    export_qa_log "$HOST_ID" "$OUT/qa-tour-$mode.log"
  done
fi

# ── (d) Le duel, deux simulateurs en parallèle (T34) ─────────────────────────
# Deux `xcodebuild test-without-building` simultanés sur la MÊME DerivedData
# sont sans risque tant que chacun a son propre -resultBundlePath (lecture
# seule du build, écriture isolée des résultats). Le guest démarre 8 s après
# l'hôte pour laisser le salon QATEST exister avant le join.
if want duel; then
  log "duel : hôte (bakarat-host) + guest (bakarat-guest, +8s)"
  xcrun simctl bootstatus "$GUEST_ID" -b >/dev/null 2>&1 || true
  sleep 30   # sim guest chaud avant de lancer les deux runners
  (
    TEST_RUNNER_BAKARAT_QA_PASSWORD="${BAKARAT_QA_PASSWORD:-}" \
      run_suite "$HOST_ID" "duel-host" -only-testing:BakaratUITests/BakaratDuelHostUITests
    export_qa_log "$HOST_ID" "$OUT/qa-duel-host.log"
  ) &
  HOST_PID=$!
  (
    sleep 8
    TEST_RUNNER_BAKARAT_QA_PASSWORD="${BAKARAT_QA_PASSWORD:-}" \
      run_suite "$GUEST_ID" "duel-guest" -only-testing:BakaratUITests/BakaratDuelGuestUITests
    export_qa_log "$GUEST_ID" "$OUT/qa-duel-guest.log"
  ) &
  GUEST_PID=$!
  wait "$HOST_PID" "$GUEST_PID"
fi

# ── (e) Export des captures + summary.json ───────────────────────────────────
SHOTS="$OUT/shots"
mkdir -p "$SHOTS"
for bundle in "$OUT"/*.xcresult; do
  [ -e "$bundle" ] || continue
  tmp="$(mktemp -d)"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; continue; }
  export BUNDLE_STEM="$(basename "$bundle" .xcresult)"
  python3 - "$tmp" "$SHOTS" <<'PYEOF'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
manifest = os.path.join(src, "manifest.json")
if not os.path.exists(manifest):
    sys.exit(0)
for test in json.load(open(manifest)):
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName", "")
        if name.startswith(("tour-", "duel-")):
            base = name.split("_0_")[0] + ".png"
            target = os.path.join(dst, base)
            if os.path.exists(target):
                target = os.path.join(dst, os.environ.get("BUNDLE_STEM", "x") + "__" + base)
            shutil.copy(os.path.join(src, att["exportedFileName"]), target)
PYEOF
  rm -rf "$tmp"
done
COUNT=$(ls "$SHOTS" 2>/dev/null | wc -l | tr -d ' ')
log "$COUNT captures dans $SHOTS"

# summary.json : durée + passed/failed par suite (via `xcresulttool get
# test-results summary`), reconnexions/conflits CAS/relèves d'hôte comptés en
# GREP HEURISTIQUE sur les logs (les tests Swift n'existent pas encore — à
# ajuster une fois leurs vrais messages XCTContext connus), captures FAIL/DIAG.
python3 - "$OUT" "$DATE" <<'PYEOF'
import json, glob, os, subprocess, sys

out_dir, run_date = sys.argv[1], sys.argv[2]
suites = {}
for bundle in sorted(glob.glob(os.path.join(out_dir, "*.xcresult"))):
    name = os.path.basename(bundle)[:-len(".xcresult")]
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary",
             "--path", bundle, "--compact"],
            capture_output=True, text=True, timeout=60, check=True).stdout
        d = json.loads(raw)
        suites[name] = {
            "result": d.get("result"),
            "passed": d.get("passedTests", 0),
            "failed": d.get("failedTests", 0),
            "total": d.get("totalTestCount", 0),
            "duration_s": round(d.get("finishTime", 0) - d.get("startTime", 0), 1),
            "failures": [f.get("testName") for f in d.get("testFailures", [])],
        }
    except Exception as e:
        suites[name] = {"result": "unknown", "error": str(e)}

shots_dir = os.path.join(out_dir, "shots")
diag_shots = []
if os.path.isdir(shots_dir):
    diag_shots = sorted(f for f in os.listdir(shots_dir) if "-FAIL-" in f or "-DIAG-" in f)

# Heuristique : compte les marqueurs si les tests/le SDK les logguent tel quel
# (à confirmer/adapter une fois BakaratUITests/BakaratTests écrits — cf plan T31/T34).
def count_marker(patterns):
    total = 0
    for logfile in glob.glob(os.path.join(out_dir, "*.log")):
        try:
            text = open(logfile, errors="ignore").read()
        except OSError:
            continue
        for p in patterns:
            total += text.count(p)
    return total

summary = {
    "run": run_date,
    "suites": suites,
    "diag_or_fail_shots": diag_shots,
    "chaos_findings": len(diag_shots),  # un DIAG/FAIL = finding C- P1 (cf online-judge.py)
    "heuristics": {
        "reconnections": count_marker(["RECONNECT", "reconnecting", "connectionState: reconnecting"]),
        "cas_conflicts": count_marker(["CAS_CONFLICT", "conflict: true", "conflict=true"]),
        "host_claims": count_marker(["HOST_CLAIM", "room_claim_host", "becomeHost"]),
    },
}
with open(os.path.join(out_dir, "summary.json"), "w") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"summary.json écrit ({len(suites)} suites, {len(diag_shots)} captures FAIL/DIAG)")
PYEOF

# ── (f) Le sommaire texte ─────────────────────────────────────────────────────
{
  echo "# Loop Online v2 — $DATE"
  echo
  echo "- Captures : $COUNT (\`shots/\`)"
  echo "- Résultats bruts : \`*.log\`, \`*.xcresult\`"
  echo "- Suites : \`summary.json\`"
  grep -hE "Test Case.*(passed|failed)" "$OUT"/*.log 2>/dev/null | sort | uniq -c | sort -rn | head -30 || true
} > "$OUT/SUMMARY.md"
log "terminé → $OUT/SUMMARY.md"

# ── (g) Le juge : les yeux de l'owner sur les captures (claude -p sur
# l'abonnement, jamais la clé API) → audits/online/ publié sur main. Un juge
# qui tombe ne doit pas faire tomber la loop. ────────────────────────────────
if [ "$NO_JUDGE" -eq 0 ] && command -v claude >/dev/null 2>&1; then
  log "juge…"
# Le guest n'a plus rien à faire : on l'éteint pour rendre le Mac au juge et au dev.
xcrun simctl shutdown "$GUEST_ID" >/dev/null 2>&1 || true

  python3 "$REPO/scripts/online-judge.py" "$OUT" >> "$OUT/judge.log" 2>&1 \
    && log "juge → audits/online/" \
    || log "juge KO (voir $OUT/judge.log)"
else
  log "juge sauté (--no-judge ou claude absent du PATH)"
fi

# ── (h) Rétention : garder les 5 derniers runs (le disque de l'owner sature) ─
ls -dt "$REPO"/audits/online/2*/ 2>/dev/null | tail -n +6 | while read -r old_run; do
  log "rétention : purge $old_run"
  rm -rf "$old_run"
done

log "run complet → $OUT"
