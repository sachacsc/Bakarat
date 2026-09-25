#!/usr/bin/env python3
"""
asc-api.py — le petit client App Store Connect de la maison (copie de
Zmeo/scripts/asc-api.py : même équipe 8ATC9B23MK, même clé API).

Pourquoi : la session Xcode de l'owner est morte (2026-08-25) et la
signature automatique n'a plus le droit au cloud-signing. Tout ce qui
touche aux certificats, aux identifiants d'app et aux profils passe donc
par l'API ASC, avec la clé `~/.zmeo-appstore.env` (ASC_KEY_ID /
ASC_ISSUER_ID) et le .p8 de `~/.appstoreconnect/private_keys/`.

Usage :
    scripts/asc-api.py GET  /v1/profiles '{"filter[name]":"Bakarat AppStore CLI"}'
    scripts/asc-api.py POST /v1/bundleIds @payload.json
    scripts/asc-api.py POST /v1/profiles  @payload.json --out profile.mobileprovision

Le jeton vit 20 minutes, il est fabriqué à chaque appel — rien n'est mis
en cache sur le disque. Les secrets ne sont jamais affichés.
"""
import json
import os
import sys
import time
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import certifi
import jwt

ENV = Path.home() / ".zmeo-appstore.env"
KEY_DIRS = [Path.home() / ".appstoreconnect" / "private_keys",
            Path.home() / ".zmeo-asc-key",
            Path.home() / "Downloads"]
BASE = "https://api.appstoreconnect.apple.com"


def credentials():
    if not ENV.exists():
        sys.exit(f"{ENV} introuvable (ASC_KEY_ID / ASC_ISSUER_ID)")
    values = {}
    for line in ENV.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    key_id = values.get("ASC_KEY_ID")
    issuer = values.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit("ASC_KEY_ID ou ASC_ISSUER_ID manquant dans ~/.zmeo-appstore.env")
    for directory in KEY_DIRS:
        candidate = directory / f"AuthKey_{key_id}.p8"
        if candidate.exists():
            return key_id, issuer, candidate.read_text()
    sys.exit(f"AuthKey_{key_id}.p8 introuvable dans {[str(d) for d in KEY_DIRS]}")


def token():
    key_id, issuer, private_key = credentials()
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def call(method, path, body=None, params=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    if data:
        request.add_header("Content-Type", "application/json")
    # Le Python de python.org n'embarque pas le magasin de certificats du
    # système : sans ce contexte, tout appel meurt en CERTIFICATE_VERIFY_FAILED.
    context = ssl.create_default_context(cafile=certifi.where())
    try:
        with urllib.request.urlopen(request, timeout=60, context=context) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except json.JSONDecodeError:
            return error.code, {"raw": raw.decode(errors="replace")[:600]}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    method, path = sys.argv[1].upper(), sys.argv[2]
    body = params = None
    out = None
    rest = sys.argv[3:]
    while rest:
        argument = rest.pop(0)
        if argument == "--out":
            out = rest.pop(0)
        elif argument.startswith("@"):
            body = json.loads(Path(argument[1:]).read_text())
        elif argument.startswith("{"):
            parsed = json.loads(argument)
            if method == "GET":
                params = parsed
            else:
                body = parsed
    status, payload = call(method, path, body=body, params=params)
    if out and status < 300:
        import base64
        content = payload.get("data", {}).get("attributes", {}).get("profileContent")
        if content:
            Path(out).write_bytes(base64.b64decode(content))
            print(f"{status} → {out}")
            return
    print(status)
    print(json.dumps(payload, indent=2)[:4000])


if __name__ == "__main__":
    main()
