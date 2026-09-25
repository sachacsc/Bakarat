# audits/online — la loop Online v2 (T30-T36)

Chaque jour à 15h (Paris), `scripts/online-loop.sh` build une fois, joue les unitaires
(`BakaratTests`, y compris les tests protocole live), le tour avec bots (`BakaratTourUITests`,
clair puis sombre) et le duel deux simulateurs (`BakaratDuelHostUITests` / `...GuestUITests`),
puis exporte tout dans un dossier local **non versionné** `audits/online/<YYYY-MM-DD-HHMM>/` :
`shots/` (captures), `*.log`, `*.xcresult`, `summary.json` (durée/passed/failed par suite,
captures `*-FAIL-*`/`*-DIAG-*`), `SUMMARY.md`.

`scripts/online-judge.py` relit ce dossier avec `claude -p` (abonnement, jamais la clé API) et
publie sur GitHub (`sachacsc/Bakarat`, branche `main`, API Contents — jamais le working tree) :
`audits/online/registry.json` (état brut), `audits/online/OPEN.md` (lisible), et le rapport du
jour `audits/online/<date>.md`.

**Lire `OPEN.md`** : items `B-xxxx` (usage/connectivité) et `C-xxxx` (scénario chaos en échec,
P1 d'office), triés par priorité ; cycle `open → still → gone → fixed`.

**Relancer à la main** : `scripts/online-loop.sh` (options `--skip-build`, `--only tour|duel|unit`,
`--no-judge`), ou juste le duel avec `scripts/duel.sh`. Juger un run existant sans relancer les
tests : `scripts/online-judge.py audits/online/<date>/ --dry-run`.
