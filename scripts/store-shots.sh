#!/bin/bash
# Captures App Store : joue BakaratStoreShotsUITests en en puis fr sur le
# simulateur iPhone 17 Pro Max « bakarat-shots » (1320×2868 = 6,9") et exporte
# les PNG dans docs/store/screenshots/<lang>/. Usage : scripts/store-shots.sh [en|fr]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Bakarat/Bakarat.xcodeproj"
DERIVED="$HOME/Library/Caches/bakarat-dd"
LANGS="${1:-en fr}"
set -a; source "$HOME/.bakarat-qa.env"; set +a
ID=$(xcrun simctl list devices | grep "bakarat-shots (" | grep -oE "[0-9A-F-]{36}" | head -1)
[ -n "$ID" ] || { echo "sim bakarat-shots absent"; exit 1; }
xcrun simctl bootstatus "$ID" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$ID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --operatorName "" || true
xcrun simctl ui "$ID" appearance light || true
for lang in $LANGS; do
  OUT="$REPO/docs/store/screenshots/$lang"; mkdir -p "$OUT"
  RES="$(mktemp -d)/store-$lang.xcresult"
  echo "== $lang"
  TEST_RUNNER_SHOT_LANG="$lang" TEST_RUNNER_BAKARAT_QA_PASSWORD="$BAKARAT_QA_PASSWORD" \
  xcodebuild test-without-building -project "$PROJECT" -scheme Bakarat \
    -destination "platform=iOS Simulator,id=$ID" -derivedDataPath "$DERIVED" \
    -parallel-testing-enabled NO -only-testing:BakaratUITests/BakaratStoreShotsUITests \
    -resultBundlePath "$RES" 2>&1 | grep -E "Test Case.*(passed|failed)|\*\* TEST" || true
  TMP="$(mktemp -d)"
  xcrun xcresulttool export attachments --path "$RES" --output-path "$TMP" >/dev/null 2>&1 || true
  python3 - "$TMP" "$OUT" <<'PY'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
m = os.path.join(src, "manifest.json")
if not os.path.exists(m): sys.exit(0)
n = 0
for test in json.load(open(m)):
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName", "")
        if name.startswith("store-"):
            base = name.split("_0_")[0]
            base = base.split("-", 2)[2] + ".png"   # store-<lang>-NN-name → NN-name.png
            shutil.copy(os.path.join(src, att["exportedFileName"]), os.path.join(dst, base)); n += 1
print(f"{n} captures → {dst}")
PY
  rm -rf "$TMP"
done
