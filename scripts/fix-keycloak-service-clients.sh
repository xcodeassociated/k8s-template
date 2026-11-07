#!/bin/bash
# Recreate/reconfigure the service-to-service OAuth2 clients ("backend" for
# spring-reactive-mongo, "backend2" for spring-reactive-r2dbc) in the Keycloak
# realm after the realm was regenerated (e.g. apps destroyed + reapplied, so
# the Keycloak DB is fresh and the realm/clients must be set up again).
#
# Symptom this fixes: GET /external/{id} returns 200 with {"data":"FALLBACK"} —
# the app's outbound client_credentials call fails and the circuit breaker
# falls back. Run on a host with kubectl access to the cluster.
#
# Reads ALL secrets from the cluster (secret-keycloak, spring-reactive-mongo-secret,
# spring-reactive-r2dbc-secret) — nothing sensitive is stored in this file.
set -e
K=https://auth.softeno.dev
ADMIN_USER=$(kubectl -n default get secret secret-keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN}' | base64 -d)
ADMIN_PW=$(kubectl -n default get secret secret-keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
T=$(curl -sk -m 8 -d "client_id=admin-cli" -d "username=$ADMIN_USER" -d "password=$ADMIN_PW" -d "grant_type=password" $K/realms/master/protocol/openid-connect/token | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
S1=$(kubectl -n default get secret spring-reactive-mongo-secret -o jsonpath='{.data.OAUTH_CLIENT_SECRET}' | base64 -d)
S2=$(kubectl -n default get secret spring-reactive-r2dbc-secret -o jsonpath='{.data.SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_KEYCLOAK_CLIENT_SECRET}' | base64 -d)

set_client() {
  CID=$1; SECRET=$2
  UUID=$(curl -sk -m 8 -H "Authorization: Bearer $T" "$K/admin/realms/app/clients?clientId=$CID" | python3 -c "import sys,json; c=json.load(sys.stdin); print(c[0]['id'] if c else '')")
  if [ -z "$UUID" ]; then
    curl -sk -m 8 -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d "{\"clientId\":\"$CID\",\"enabled\":true,\"protocol\":\"openid-connect\",\"publicClient\":false,\"serviceAccountsEnabled\":true,\"secret\":\"$SECRET\"}" "$K/admin/realms/app/clients"
    set_client "$CID" "$SECRET"
  else
    curl -sk -m 8 -H "Authorization: Bearer $T" -H "Content-Type: application/json" -X PUT -d "{\"id\":\"$UUID\",\"clientId\":\"$CID\",\"secret\":\"$SECRET\",\"enabled\":true,\"protocol\":\"openid-connect\",\"publicClient\":false,\"serviceAccountsEnabled\":true,\"bearerOnly\":false}" "$K/admin/realms/app/clients/$UUID"
    CUR=$(curl -sk -m 8 -H "Authorization: Bearer $T" "$K/admin/realms/app/clients/$UUID/client-secret" | python3 -c "import sys,json;print(json.load(sys.stdin)['value'])")
    if [ "$CUR" = "$SECRET" ]; then echo "$CID: secret matches"; else echo "$CID: secret MISMATCH"; return 1; fi
    R=$(curl -sk -m 8 -d "client_id=$CID" -d "client_secret=$SECRET" -d "grant_type=client_credentials" $K/realms/app/protocol/openid-connect/token | python3 -c "import sys,json; d=json.load(sys.stdin); print('TOKEN-OK' if 'access_token' in d else 'FAIL:'+str(d.get('error_description')))")
    echo "$CID: $R"
    [ "$R" = "TOKEN-OK" ]
  fi
}
set_client backend "$S1"
set_client backend2 "$S2"
