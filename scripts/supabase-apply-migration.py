#!/usr/bin/env python3
"""
Applique une migration `supabase/migrations/<timestamp>_<nom>.sql` sur la base LIVE
Bakarat via l'API de gestion Supabase (PAT dans ~/.zmeo-supabase.env, même compte),
sans mot de passe DB ni `supabase db push`. Port du script Zmeo.

  scripts/supabase-apply-migration.py --list                 # historique live
  scripts/supabase-apply-migration.py --gap                  # fichiers du dépôt absents du live
  scripts/supabase-apply-migration.py 20260925100000_online_rooms.sql

Chaque fichier appliqué est ENREGISTRÉ dans `supabase_migrations.schema_migrations`
(version = préfixe timestamp, name = reste). Une requête = une transaction côté API :
si le SQL échoue, rien n'est écrit. Geste owner / session mandatée, jamais une loop.
"""
import json
import os
import subprocess
import sys

PROJECT_REF = "wwutjnqchxzdfxmhfaaj"
API = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
MIG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "supabase", "migrations")


def load_pat() -> str:
    path = os.path.expanduser("~/.zmeo-supabase.env")
    with open(path) as fh:
        for line in fh:
            if line.startswith("SUPABASE_PAT="):
                return line.split("=", 1)[1].strip().strip('"')
    sys.exit("SUPABASE_PAT introuvable dans ~/.zmeo-supabase.env")


def query(pat: str, sql: str):
    """curl plutôt qu'urllib : le python3 système n'a pas les certificats racine."""
    proc = subprocess.run(
        ["curl", "-sS", "--fail-with-body", "-X", "POST", API,
         "-H", f"Authorization: Bearer {pat}", "-H", "Content-Type: application/json",
         "--data-binary", "@-"],
        input=json.dumps({"query": sql}), capture_output=True, text=True, timeout=300,
    )
    if proc.returncode != 0:
        raise SystemExit(f"curl {proc.returncode}: {proc.stdout[:2000].strip() or proc.stderr.strip()}")
    return json.loads(proc.stdout) if proc.stdout.strip() else []


def live_versions(pat: str) -> dict:
    rows = query(pat, "select version, name from supabase_migrations.schema_migrations order by version")
    return {row["version"]: row.get("name") for row in rows}


def split_name(filename: str):
    base = os.path.basename(filename)
    assert base.endswith(".sql"), base
    version, _, rest = base[:-4].partition("_")
    return version, rest


def main(argv):
    pat = load_pat()
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--list":
        for v, n in live_versions(pat).items():
            print(v, n)
        return 0
    if argv[0] == "--gap":
        live = live_versions(pat)
        for f in sorted(os.listdir(MIG_DIR)):
            if f.endswith(".sql") and split_name(f)[0] not in live:
                print(f)
        return 0
    live = live_versions(pat)
    for f in argv:
        version, name = split_name(f)
        path = f if os.path.exists(f) else os.path.join(MIG_DIR, os.path.basename(f))
        if version in live:
            print(f"déjà appliquée : {version} {name}")
            continue
        sql = open(path).read()
        print(f"→ applique {os.path.basename(path)} ({len(sql)} octets)…")
        query(pat, sql)
        query(pat, "insert into supabase_migrations.schema_migrations(version, name) values (%s, %s) on conflict do nothing"
              % (json.dumps(version).replace('"', "'"), json.dumps(name).replace('"', "'")))
        print(f"✓ {version} {name} enregistrée")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
