#!/bin/bash
# Keep-alive du projet Supabase Bakarat (plan gratuit : pause automatique après
# 7 jours sans requête — vécu le 2026-09-25, projet INACTIVE depuis mai).
# Une requête REST authentifiée par jour suffit à compter comme « activité ».
# Si le projet est quand même en pause, on le restaure par l'API de gestion
# (PAT du compte dans ~/.zmeo-supabase.env, même compte Supabase que Zmeo).
# Usage : scripts/supabase-keepalive.sh   (launchd : com.bakarat.keepalive, 09:15)
set -uo pipefail
REF="wwutjnqchxzdfxmhfaaj"
URL="https://$REF.supabase.co"
ANON=$(grep -o "eyJ[^']*" "$(dirname "$0")/../supabase-config.js" | head -1)
log() { echo "[keepalive $(date '+%F %T')] $*"; }

code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  "$URL/rest/v1/profiles?select=user_id&limit=1")
log "REST → $code"
[ "$code" = "200" ] && exit 0

# Pas de 200 : on regarde le statut côté gestion et on restaure si besoin.
set -a; source "$HOME/.zmeo-supabase.env" 2>/dev/null; set +a
[ -z "${SUPABASE_PAT:-}" ] && { log "pas de PAT, abandon"; exit 1; }
status=$(curl -s --max-time 20 -H "Authorization: Bearer $SUPABASE_PAT" \
  "https://api.supabase.com/v1/projects/$REF" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
log "statut projet → $status"
if [ "$status" = "INACTIVE" ]; then
  r=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $SUPABASE_PAT" \
    "https://api.supabase.com/v1/projects/$REF/restore")
  log "restore → HTTP $r"
fi
