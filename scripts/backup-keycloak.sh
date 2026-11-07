#!/bin/bash
# Real backup of Keycloak: realm JSON + both Postgres DB dumps.
# Run on the cluster master. Output -> keycloak-realm/ (gitignored, contains secrets).
# Restore with scripts/restore-keycloak.sh.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)/keycloak-realm"
mkdir -p "$DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 "$SCRIPT_DIR/export-realm.py" "$DIR/app-realm.json"

# Find CNPG primaries (instance pod whose role label is primary)
dump_db() {
  local cluster=$1 db=$2 out=$3
  local pod
  pod=$(kubectl -n postgres get pods -l "cnpg.io/cluster=$cluster,role=primary" -o jsonpath='{.items[0].metadata.name}')
  kubectl -n postgres exec "$pod" -- pg_dump -U postgres -d "$db" > "$out"
  echo "dumped $db -> $out ($(wc -c < "$out") bytes)"
}
dump_db postgres-keycloak keycloak "$DIR/backup-keycloak.dump"
dump_db postgres-app application "$DIR/backup-application.dump"
echo "backup complete: $DIR"
