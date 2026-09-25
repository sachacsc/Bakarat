#!/bin/bash
# release-testflight.sh — archive, exporte, valide et envoie une build Bakarat
# sur App Store Connect, en UNE commande. Port de Zmeo/scripts/release-testflight.sh
# (T41, docs/PLAN_ONLINE_V2.md).
#
# POURQUOI CE SCRIPT EXISTE
# App Store Connect rejette les binaires d'un Xcode BÊTA (« Unsupported SDK or
# Xcode version » — vécu sur Zmeo le 2026-08-09, estampille Xcode `27A5194q`).
# Le script force une toolchain FINALE et refuse de livrer avec une bêta.
# Une bêta se reconnaît au nom du bundle (« Xcode-beta.app ») ET au numéro de
# build : une build finale est `27A266a` (lettre minuscule seule en suffixe
# éventuel, 7 caractères max), une bêta `27A5194q` (4 chiffres + lettre).
#
# USAGE
#   scripts/release-testflight.sh                # archive → export → valide, PUIS demande confirmation
#   scripts/release-testflight.sh --yes          # ... et envoie sans demander (CI / non-interactif)
#   scripts/release-testflight.sh --no-upload    # s'arrête après la validation
#   scripts/release-testflight.sh --check        # vérifie seulement les prérequis
#
# IDENTIFIANTS : lus depuis ~/.zmeo-appstore.env (0600, partagé avec Zmeo —
# même équipe 8ATC9B23MK), jamais en argument. Surcharge : ASC_ENV_FILE=...
#   ASC_USER=...
#   ASC_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
#   ASC_KEY_ID=... / ASC_ISSUER_ID=...     (optionnels : signature par clé API)
# Le mot de passe n'est jamais écrit sur la sortie : il passe par `@env:` et
# toute trace est masquée.
#
# SIGNATURE : archive en automatique (développement), export en MANUEL avec le
# profil « Bakarat AppStore CLI » (voir scripts/ExportOptions-appstore.plist et
# scripts/asc-api.py pour le créer).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Bakarat/Bakarat.xcodeproj"
SCHEME="Bakarat"
APP_NAME="Bakarat"
XCODE_APP="${XCODE_APP:-/Applications/Xcode.app}"
ENV_FILE="${ASC_ENV_FILE:-$HOME/.zmeo-appstore.env}"
OUT="${RELEASE_OUT:-$HOME/Desktop}"
# JAMAIS /tmp : l'archive survit au script (symboles, re-export, diagnostic).
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/Library/Caches/bakarat-archive}"
PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
DO_UPLOAD=1
ASSUME_YES=0
CHECK_ONLY=0

for a in "$@"; do
  case "$a" in
    --yes|-y)     ASSUME_YES=1 ;;
    --no-upload)  DO_UPLOAD=0 ;;
    --check)      CHECK_ONLY=1 ;;
    -h|--help)    sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "option inconnue : $a"; exit 2 ;;
  esac
done

die() { echo "✖ $*" >&2; exit 1; }

# ── 1. La toolchain ─────────────────────────────────────────────────────────
[ -d "$XCODE_APP" ] || die "Xcode introuvable : $XCODE_APP"

# Refuser une bêta. C'est LA cause du rejet qu'on veut rendre impossible.
case "$(basename "$XCODE_APP")" in
  *beta*|*Beta*) die "« $XCODE_APP » est une bêta — App Store Connect refusera le binaire.
   Vise l'Xcode final (XCODE_APP=/Applications/Xcode.app)." ;;
esac

export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
XC_VER="$(xcodebuild -version 2>/dev/null | head -1)"
XC_BUILD="$(defaults read "$XCODE_APP/Contents/version.plist" ProductBuildVersion 2>/dev/null)"
[ -n "$XC_BUILD" ] || die "numéro de build d'Xcode illisible ($XCODE_APP/Contents/version.plist)"
# Estampille bêta = 4 chiffres + lettre après la lettre de train (27A5194q).
if [[ "$XC_BUILD" =~ ^[0-9]+[A-Z][0-9]{4,}[a-z]$ ]]; then
  die "$XC_VER ($XC_BUILD) est une build BÊTA — App Store Connect refusera le binaire."
fi
SDK="$(xcodebuild -showsdks 2>/dev/null | grep -o 'iphoneos[0-9.]*' | tail -1)"
[ -n "$SDK" ] || die "aucun SDK iOS dans $XCODE_APP"

N_XCODES="$(ls -d /Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app 2>/dev/null | wc -l | tr -d ' ')"
echo "Toolchain : $XC_VER ($XC_BUILD, finale) — SDK $SDK"
[ "$N_XCODES" = 1 ] && echo "            (seul Xcode installé : accepté, c'est une finale)"

# ── 2. Les identifiants ─────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die "identifiants absents : $ENV_FILE
   Attendu : ASC_USER=... et ASC_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx (chmod 600)"
perms="$(stat -f '%OLp' "$ENV_FILE")"
[ "$perms" = "600" ] || echo "⚠ $ENV_FILE est en $perms — attendu 600 (chmod 600 \"$ENV_FILE\")"
set -a; . "$ENV_FILE"; set +a
[ -n "${ASC_USER:-}" ] && [ -n "${ASC_APP_PASSWORD:-}" ] || die "ASC_USER ou ASC_APP_PASSWORD manquant dans $ENV_FILE"
mask() { sed "s/${ASC_APP_PASSWORD//\//\\/}/«masqué»/g"; }

# ── 2bis. Clé API App Store Connect (signature SANS session Xcode) ──────────
# La session Apple ID de la machine est morte depuis le 2026-08-25 (vécu sur
# Zmeo : « No Accounts »). Si ASC_KEY_ID + ASC_ISSUER_ID sont dans $ENV_FILE,
# xcodebuild s'authentifie par la clé (`AuthKey_<ID>.p8`, cherchée dans
# ~/.appstoreconnect/private_keys/ sauf ASC_KEY_P8 explicite).
AUTH_ARGS=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  KEY_P8="${ASC_KEY_P8:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  [ -f "$KEY_P8" ] || die "clé API introuvable : $KEY_P8"
  AUTH_ARGS=(-authenticationKeyPath "$KEY_P8" \
             -authenticationKeyID "$ASC_KEY_ID" \
             -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "Signature : clé API ASC $ASC_KEY_ID (session Xcode non requise)"
fi

# ── 3. La version ───────────────────────────────────────────────────────────
# Apple REFUSE deux uploads portant le même couple version/build, et ne le dit
# qu'APRÈS le transfert (`--validate-app` ne le détecte pas). Les valeurs vivent
# dans les réglages (GENERATE_INFOPLIST_FILE = YES), pas dans un Info.plist.
SETTINGS="$(xcodebuild -showBuildSettings -project "$PROJECT" \
             -scheme "$SCHEME" -configuration Release 2>/dev/null)"
SHORT="$(echo "$SETTINGS" | awk '/^ *MARKETING_VERSION /{print $3; exit}')"
BUILD="$(echo "$SETTINGS" | awk '/^ *CURRENT_PROJECT_VERSION /{print $3; exit}')"
[ -n "$SHORT" ] || SHORT='?'
[ -n "$BUILD" ] || BUILD='?'
echo "Version   : $SHORT ($BUILD)  ← doit être INÉDITE sur App Store Connect"

EXPORT_PLIST="$REPO/scripts/ExportOptions-appstore.plist"
[ -f "$EXPORT_PLIST" ] || die "ExportOptions absent : $EXPORT_PLIST"

# Toutes les cibles au MÊME numéro de build (app + tests aujourd'hui ; une
# future extension devra suivre, App Store refuse un CFBundleVersion divergent).
VERSIONS="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*;' "$PROJECT/project.pbxproj" | sort -u)"
if [ "$(printf '%s\n' "$VERSIONS" | wc -l | tr -d ' ')" != "1" ]; then
  printf '%s\n' "$VERSIONS"
  die "les cibles n'ont pas le même numéro de build — aligne CURRENT_PROJECT_VERSION avant d'archiver."
fi

# ── 3bis. Les profils de distribution (signature manuelle) ──────────────────
# Chaque bundle listé dans ExportOptions doit avoir son profil INSTALLÉ, non
# expiré ; et un cert Apple Distribution doit être dans les trousseaux.
# Sans ça l'export meurt après l'archive — on le dit avant.
DIST_SHA="$(security find-certificate -a -c "Apple Distribution" -Z 2>/dev/null \
  | awk '/SHA-1/{print $3}' | head -1)"
MISSING=0
while IFS=$'\t' read -r bundle pname; do
  [ -n "$bundle" ] || continue
  found=""
  for f in "$PROFILES_DIR"/*.mobileprovision; do
    [ -f "$f" ] || continue
    plist="$(security cms -D -i "$f" 2>/dev/null)" || continue
    n="$(/usr/libexec/PlistBuddy -c 'Print :Name' /dev/stdin <<<"$plist" 2>/dev/null)"
    [ "$n" = "$pname" ] || continue
    exp="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' /dev/stdin <<<"$plist" 2>/dev/null)"
    exp_s="$(date -j -f '%a %b %d %T %Z %Y' "$exp" +%s 2>/dev/null || echo 0)"
    [ "$exp_s" -gt "$(date +%s)" ] || { echo "⚠ profil « $pname » EXPIRÉ ($exp)"; continue; }
    found="$f"; break
  done
  if [ -n "$found" ]; then
    echo "Profil    : « $pname » → $bundle ✔"
  else
    echo "✖ profil « $pname » ($bundle) absent de $PROFILES_DIR"
    MISSING=1
  fi
done < <(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles' "$EXPORT_PLIST" 2>/dev/null \
          | sed -n 's/^ *\([^ ]*\) = \(.*\)$/\1\t\2/p')
[ -n "$DIST_SHA" ] || die "aucun certificat « Apple Distribution » dans les trousseaux."
[ "$MISSING" = 0 ] || die "profil(s) de distribution manquant(s) — à créer par l'API ASC :
     voir « TestFlight » dans docs/INFRA.md (scripts/asc-api.py POST /v1/profiles …)"

# La clé privée de distribution vit dans un trousseau dédié (`zmeo-dist`,
# partagé avec Zmeo). Verrouillé, `codesign` meurt en `errSecInternalComponent`
# APRÈS l'archive. On le dit avant, sur une sonde.
PROBE="$(mktemp -t bakarat-sign-probe)"
cp /bin/echo "$PROBE"
# Sortie capturée, PAS canalisée : sous `pipefail`, `| grep -q` rendrait
# l'échec de codesign et le garde ne se déclencherait jamais.
PROBE_OUT="$(codesign --force --sign "Apple Distribution" "$PROBE" 2>&1 || true)"
rm -f "$PROBE"
case "$PROBE_OUT" in *errSecInternalComponent*)
  die "trousseau de distribution VERROUILLÉ — codesign ne peut pas signer.
     security unlock-keychain ~/Library/Keychains/zmeo-dist.keychain-db
   (mot de passe : ~/.zmeo-dist-cert/kc-pass) puis, une seule fois :
     security set-key-partition-list -S apple-tool:,apple:,codesign: -s \\
       -k <mot-de-passe-du-trousseau> ~/Library/Keychains/zmeo-dist.keychain-db" ;;
esac
echo "Trousseau : codesign « Apple Distribution » OK"

if [ "$CHECK_ONLY" = 1 ]; then echo "✔ prérequis OK"; exit 0; fi

# ── 4. Archive ──────────────────────────────────────────────────────────────
STAMPED="$APP_NAME-$SHORT-$BUILD"
WORK="$ARCHIVE_DIR/$STAMPED"
rm -rf "$WORK"; mkdir -p "$WORK"
ARCHIVE="$WORK/$APP_NAME.xcarchive"
echo "→ archive… ($WORK)"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} > "$WORK/archive.log" 2>&1 \
  || { grep -E "error:" "$WORK/archive.log" | head -5; die "archive échouée (log: $WORK/archive.log)"; }

# Garde-fou : c'est l'estampille du binaire, pas la version d'Xcode, qu'Apple
# contrôle. On la vérifie AVANT de transférer quoi que ce soit.
APP_PLIST="$ARCHIVE/Products/Applications/$APP_NAME.app/Info.plist"
STAMP="$(defaults read "$APP_PLIST" DTSDKName 2>/dev/null)"
STAMP_XC="$(defaults read "$APP_PLIST" DTXcodeBuild 2>/dev/null)"
echo "  estampille : SDK $STAMP / Xcode $STAMP_XC"
case "$STAMP" in
  iphoneos2[0-5].*) die "SDK trop ancien ($STAMP) — Apple exige iOS 26+ depuis le 2026-04-28." ;;
esac
if [[ "$STAMP_XC" =~ ^[0-9]+[A-Z][0-9]{4,}[a-z]$ ]]; then
  die "binaire estampillé par une Xcode BÊTA ($STAMP_XC) — Apple le refusera."
fi

# ── 5. Export ───────────────────────────────────────────────────────────────
echo "→ export…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
  -exportOptionsPlist "$EXPORT_PLIST" -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} > "$WORK/export.log" 2>&1 \
  || { grep -E "error:" "$WORK/export.log" | head -5; die "export échoué (log: $WORK/export.log)"; }

IPA="$(ls "$WORK/export"/*.ipa 2>/dev/null | head -1)"
[ -n "$IPA" ] || die "aucun .ipa produit"
FINAL="$OUT/$STAMPED.ipa"
cp "$IPA" "$FINAL"
echo "  ipa : $FINAL ($(du -h "$FINAL" | cut -f1))"

# ── 6. Validation (ne publie RIEN) ──────────────────────────────────────────
echo "→ validation chez Apple…"
if ! xcrun altool --validate-app -f "$FINAL" -t ios -u "$ASC_USER" -p @env:ASC_APP_PASSWORD 2>&1 \
     | mask | tee "$WORK/validate.log" | grep -q "VERIFY SUCCEEDED"; then
  tail -15 "$WORK/validate.log"
  die "validation refusée — rien n'a été publié."
fi
echo "  ✔ VERIFY SUCCEEDED"

[ "$DO_UPLOAD" = 1 ] || { echo "✔ arrêt demandé avant l'envoi (--no-upload)."; exit 0; }

# ── 7. Envoi (VISIBLE PAR LES TESTEURS) ─────────────────────────────────────
if [ "$ASSUME_YES" != 1 ]; then
  if [ ! -t 0 ]; then die "envoi non confirmé : ajoute --yes en non-interactif."; fi
  printf "Envoyer %s (%s) sur App Store Connect ? [o/N] " "$SHORT" "$BUILD"
  read -r ans
  case "$ans" in o|O|y|Y) ;; *) echo "annulé — rien n'a été publié."; exit 0 ;; esac
fi

echo "→ envoi…"
xcrun altool --upload-app -f "$FINAL" -t ios -u "$ASC_USER" -p @env:ASC_APP_PASSWORD 2>&1 \
  | mask | tee "$WORK/upload.log" | tail -8
grep -q "UPLOAD SUCCEEDED" "$WORK/upload.log" || die "envoi échoué."
echo "✔ envoyé. Le traitement Apple prend 10 min à 1 h avant TestFlight."
