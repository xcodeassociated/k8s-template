#!/usr/bin/env python3
"""Export Keycloak realm 'app' as importable JSON via the admin CRUD API.

Run on a host with kubectl access to the cluster. The /admin/realms/<realm>/export
endpoint 404s with this hostname config, so clients/roles/users are assembled
individually. Client secrets are read live from the client-secret endpoint.
Reads admin credentials from cluster secrets — nothing is stored here.
Output: /tmp/kcrealm/<realm>-realm.json (or path given as argv[1]).
"""
import json, subprocess, sys

K = "https://auth.softeno.dev"
REALM = "app"
OUT = sys.argv[1] if len(sys.argv) > 1 else f"/tmp/kcrealm/{REALM}-realm.json"

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

TOKEN = ""

def curl(url, method=None, data=None):
    cmd = ["curl", "-sk", "-m", "10"]
    if TOKEN:
        cmd += ["-H", f"Authorization: Bearer {TOKEN}"]
    if data is not None:
        if method:
            cmd += ["-X", method]
        cmd += ["-H", "Content-Type: application/x-www-form-urlencoded", "-d", data]
    cmd.append(url)
    return subprocess.run(cmd, capture_output=True, text=True).stdout

ADMIN_USER = sh("kubectl -n default get secret secret-keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN}' | base64 -d")
ADMIN_PW = sh("kubectl -n default get secret secret-keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d")
r = curl(f"{K}/realms/master/protocol/openid-connect/token", method="POST",
         data=f"client_id=admin-cli&username={ADMIN_USER}&password={ADMIN_PW}&grant_type=password")
TOKEN = json.loads(r)["access_token"]

realm = json.loads(curl(f"{K}/admin/realms/{REALM}"))
realm["clients"] = []
for c in json.loads(curl(f"{K}/admin/realms/{REALM}/clients?first=0&max=100")):
    full = json.loads(curl(f"{K}/admin/realms/{REALM}/clients/{c['id']}"))
    if not full.get("publicClient", True) and not full.get("bearerOnly", False):
        sec = json.loads(curl(f"{K}/admin/realms/{REALM}/clients/{c['id']}/client-secret"))
        full["secret"] = sec.get("value")
    full.pop("id", None)
    realm["clients"].append(full)

realm["users"] = json.loads(curl(f"{K}/admin/realms/{REALM}/users"))
groups = json.loads(curl(f"{K}/admin/realms/{REALM}/groups"))
if groups:
    realm["groups"] = groups
roles = json.loads(curl(f"{K}/admin/realms/{REALM}/roles"))
realm["roles"] = {"realm": [x for x in roles if not x.get("clientRole")]}

realm.pop("notBefore", None)
import os
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(realm, f, indent=1)
print(f"exported: realm={realm.get('realm')} clients={len(realm['clients'])} "
      f"users={len(realm['users'])} roles={len(realm['roles']['realm'])} -> {OUT}")
