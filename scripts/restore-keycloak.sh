#!/bin/bash
# Restore Keycloak from backups created by scripts/backup-keycloak.sh.
# Run on the cluster master. Reads credentials from cluster secrets only.
#
#   ./restore-keycloak.sh            # restore both Postgres DBs from dumps
#   ./restore-keycloak.sh --realm-json  # additionally (re)import realm JSON via admin API
#
# DB restore drops + recreates the databases on the CNPG clusters, so stop the
# dependent apps first (the script does it and restarts them afterwards).
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)/keycloak-realm"
K=https://auth.softeno.dev
IMPORT_REALM=false
[ "${1:-}" = "--realm-json" ] && IMPORT_REALM=true

restore_db() {
  local cluster=$1 db=$2 owner=$3 dump=$4
  local pod
  pod=$(kubectl -n postgres get pods -l "cnpg.io/cluster=$cluster,role=primary" -o jsonpath='{.items[0].metadata.name}')
  kubectl -n postgres cp "$dump" "$pod:/controller/restore.dump"
  kubectl -n postgres exec "$pod" -- psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)"
  kubectl -n postgres exec "$pod" -- psql -U postgres -d postgres -c "CREATE DATABASE $db OWNER $db"
  kubectl -n postgres exec "$pod" -- psql -U postgres -d "$db" -q -f /controller/restore.dump 2>&1 | grep -i error && { echo "restore of $db had errors"; return 1; } || true
  echo "restored $db on $cluster"
}

kubectl -n default scale deploy/keycloak --replicas=0
kubectl -n default scale deploy/spring-reactive-r2dbc --replicas=0
restore_db postgres-keycloak keycloak keycloak "$DIR/backup-keycloak.dump"
restore_db postgres-app application admin "$DIR/backup-application.dump"
kubectl -n default scale deploy/keycloak --replicas=1
kubectl -n default scale deploy/spring-reactive-r2dbc --replicas=1

if $IMPORT_REALM; then
  echo "NOTE: realm JSON import only recreates realm config/clients/roles/users-without-passwords;"
  echo "      prefer the DB dump restore for full fidelity (password hashes)."
  ADMIN_USER=$(kubectl -n default get secret secret-keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN}' | base64 -d)
  ADMIN_PW=$(kubectl -n default get secret secret-keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
  T=$(curl -sk -m 8 -d "client_id=admin-cli" -d "username=$ADMIN_USER" -d "password=$ADMIN_PW" -d "grant_type=password" $K/realms/master/protocol/openid-connect/token | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
  curl -sk -m 15 -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data @"$DIR/app-realm.json" "$K/admin/realms" \
    && echo "realm imported" || echo "realm import returned non-204 (realm may already exist — delete it first or use DB restore)"
fi
echo "restore complete"
