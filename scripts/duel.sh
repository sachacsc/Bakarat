#!/bin/bash
# Le duel seul — lanceur autonome pour le dev (T34). Réutilise online-loop.sh
# avec `--only duel --skip-build` : suppose une build-for-testing déjà faite
# dans ~/Library/Caches/bakarat-loop-dd (lancer online-loop.sh une première
# fois, ou `xcodebuild build-for-testing` à la main, sinon test-without-building
# échouera). Pratique pour rejouer vite les scénarios de reconnexion sans
# repasser par le tour ni les unitaires.
#
# Usage : scripts/duel.sh [--force-build] [autres options online-loop.sh]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--force-build" ]; then
  shift
  exec "$REPO/scripts/online-loop.sh" --only duel "$@"
fi

exec "$REPO/scripts/online-loop.sh" --only duel --skip-build "$@"
