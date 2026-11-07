# AGENTS.md

Guidance for coding agents working in this repository.

## What this repo is

A **template Kubernetes manifest stack** (plain YAML, no application source, no build system, no CI) for deploying three companion template services in a small production-like cluster:

- `spring-reactive-mongo` — [spring-reactive-template](https://github.com/xcodeassociated/spring-reactive-template) (Spring reactive + MongoDB + Kafka)
- `spring-reactive-r2dbc` — [spring-reactive-r2dbc-template](https://github.com/xcodeassociated/spring-reactive-r2dbc-template) (Spring reactive + R2DBC/PostgreSQL + Kafka)
- `react-typescript-template` — [react-typescript-vite-plus-template](https://github.com/xcodeassociated/react-typescript-vite-plus-template) frontend

Shared dependencies: PostgreSQL (CloudNativePG), MongoDB (Community Operator), Kafka (Strimzi), Grafana otel-lgtm, Keycloak. Treat this repo as a template: copy it, rename resources/domains/images, and replace the secret workflow before real use. It is intended to be public-repo safe — never commit real credentials, kubeconfigs, keys, or generated secret files.

## Layout

- `dependencies/` — cluster-level infra, applied in numeric order: `00-namespaces.yaml` (kafka, postgres, mongo, grafana), `01-secrets.template.yaml`, `02-postgres.yaml` (CNPG `Cluster`s `postgres-app` + `postgres-keycloak`), `03-mongo.yaml` (`MongoDBCommunity mongodb-rs`), `04-kafka.yaml` (Strimzi node pools, `KafkaTopic`s, kafka-ui), `05-grafana.yaml` (otel-lgtm stack).
- `apps/` — `01-secrets.template.yaml`, `02-keycloak.yaml`, `03-spring-reactive-template.yaml`, `04-spring-reactive-r2dbc.yaml`, `05-react-typescript-template.yaml` (Deployment + Service + Ingress each).
- `README.md` — full deploy/cleanup walkthrough; keep it and this file consistent.

Dependencies live in their own namespaces; **all apps deploy to the `default` namespace** (no `namespace:` in app manifests). Ingress hosts use `*.softeno.dev` (api, auth, app, kafka, otel) behind nginx ingress + cert-manager annotation `cert-manager.io/cluster-issuer: acme-issuer`. Storage uses `storageClass: longhorn`.

## Secrets workflow

- `*/01-secrets.template.yaml` are **committed placeholders only**; `**/*secrets.yaml` files are gitignored local files. Create locals with `cp <dir>/01-secrets.template.yaml <dir>/01-secrets.yaml` and fill real values.
- Cross-references that must match (enforced by convention, not tooling):
  - `mongodb-admin-password.password` ↔ `spring-reactive-mongo-secret.MONGO_PASSWORD`
  - `postgres-app-credentials.password` ↔ `spring-reactive-r2dbc-secret.SPRING_R2DBC_PASSWORD` and `SPRING_LIQUIBASE_PASSWORD`
  - `postgres-keycloak-credentials.password` ↔ `secret-keycloak.KC_DB_PASSWORD`
  - OAuth client secrets ↔ clients configured in Keycloak.
  - `spring-reactive-mongo-secret.OAUTH_CLIENT_SECRET` ↔ Keycloak client `backend`; `spring-reactive-r2dbc-secret.SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_KEYCLOAK_CLIENT_SECRET` ↔ client `backend2` (both service-account / client-credentials; see "Realm recovery").
- For production GitOps, replace this manual workflow with External Secrets, SOPS, or Sealed Secrets.

## App user credentials (UI / Playwright checks)

End-user login credentials for the deployed app live in the repo-root **`.credential`** file (gitignored; `.credential.template` is the committed placeholder). When checking the app through the UI (e.g. Playwright against `https://app.softeno.dev`), read `.credential` and log in with those users instead of asking the user. If the file is missing, copy the template and ask the user to fill it.

**What to test**: the app itself is a simple template — discover the basic flow from the frontend repo `/Users/xcodeassociated/code/react-typescript-vite-plus-template` (read its `AGENTS.md`, especially "Local Login" and "Verified flows"). Core smoke: login via Keycloak (`auth.softeno.dev`) → users list/CRUD + roles widget → counter persistence → live SSE updates (second user sees changes); plus swagger reachable at `api.softeno.dev`. Keep each check fast (see below) and report failures immediately.

**How to verify (mandatory)**: when testing whether the app is working, ALWAYS verify the **frontend through Playwright** (drive the real browser: login, navigate, exercise the flow, check console for errors) and the **backend through logs** (`kubectl -n default logs deploy/<app> -c <app>` — look for startup success, exceptions/stack traces, and Kafka/Keycloak event flow). Do not claim the app works from HTTP status codes alone. When finished, ALWAYS close the Playwright browser (`browser_close`) so no session is left running.

**`/external` endpoints (always test)**: each backend proxies `/external/{id}` to the *other* backend's `/sample-secured/{id}` (OAuth2 client-credentials between services; inbound path requires `ROLE_ADMIN`). Test with a user bearer token from `.credential` (password grant against realm `app`, client `frontend`, then `GET https://api.softeno.dev/spring-reactive-template/external/1` and `/spring-reactive-r2dbc-template/external/1`). Expected: `200 {"data":"<id>"}`. A `200 {"data":"FALLBACK"}` means the endpoint is up but the outbound service token is broken — see realm recovery below. `/external/grpc/{data}` currently 500s from a grpc-java classpath conflict inside the `:latest` images (image-build issue, not cluster config).

**Realm recovery (after the apps are destroyed + reapplied)**: wiping Keycloak's DB and recreating the realm loses the service-to-service clients `backend` (mongo app) and `backend2` (r2dbc app). They must be confidential, service-account-enabled, with client secrets equal to the values in the app k8s secrets (`OAUTH_CLIENT_SECRET` / `SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_KEYCLOAK_CLIENT_SECRET`). Fix by running `scripts/fix-keycloak-service-clients.sh` on the cluster master — it reads all credentials from the cluster secrets at runtime (no credentials in the repo). Verify: `client_credentials` token request succeeds for both clients and `/external/1` returns real data. Note: running the script (or `/external`) also reveals whether the destroy actually wiped the DB — see the destroy-race gotcha below.

**Backups (before any destructive wipe)**: use `scripts/backup-keycloak.sh` on the master — exports realm `app` as importable JSON (`scripts/export-realm.py`; the `/export` admin endpoint 404s with this hostname config) plus `pg_dump` of the `keycloak` and `application` DBs into repo-root `keycloak-realm/` (gitignored, contains secrets). Restore with `scripts/restore-keycloak.sh` (DB dumps = full fidelity incl. password hashes; `--realm-json` = config/clients/roles/users but WITHOUT user passwords — admin API export omits credential hashes, so logins fail until passwords are reset). Both paths are tested: dump restore verified byte-identical credentials in a scratch DB; realm JSON verified to import cleanly into a fresh Keycloak (clients, ROLE_ADMIN, users). CNPG pods have a read-only `/tmp` — the scripts use `/controller` for staging files.

**Destroy race gotcha**: `kubectl delete <cr> --wait=false` immediately followed by `kubectl apply` can *cancel* the deletion — CNPG/Strimzi objects get re-written mid-terminate, pods keep running, and PVCs hang in `Terminating` with old data intact. For a real wipe: delete, wait until the objects AND PVCs are actually gone (`kubectl get pvc -n <ns>` empty), then apply. Verify a wipe via `kubectl -n postgres get clusters.postgresql.cnpg.io` age / PVC ages.

## Scripts (run on the cluster master, e.g. `ssh worker@kube-0.lan 'bash ~/k8s-template/scripts/<name>'`)

| Script | Purpose / usage |
|---|---|
| `scripts/backup-keycloak.sh` | Real backup: exports realm `app` JSON + `pg_dump` of `keycloak` and `application` DBs into `keycloak-realm/` (gitignored). Run BEFORE any destructive wipe. |
| `scripts/restore-keycloak.sh` | Restores both DBs from the dumps (auto-scales keycloak/r2dbc to 0, drop+create DBs, `psql -f`, scales back). Add `--realm-json` to also import the realm via admin API. DB dumps are the full-fidelity path (keeps password hashes). |
| `scripts/export-realm.py` | Realm-JSON assembler used by backup (admin CRUD API; the `/export` endpoint 404s with this hostname config). Rarely run standalone. |
| `scripts/fix-keycloak-service-clients.sh` | After a realm regeneration (apps destroyed + reapplied): re-creates/fixes the `backend`/`backend2` service-account clients from cluster secrets. Symptom it fixes: `/external/{id}` returns `{"data":"FALLBACK"}`. |

All scripts read credentials from cluster secrets at runtime — never hardcode or print secrets in them or in the repo.

## Commands

There is no build, test, or lint step. Work is validated against a cluster with `kubectl` (context must point at the target cluster):

**Keep checks fast.** Use short timeouts (max ~15–20s per command/poll) and fail fast: prefer one quick sample of pod/rollout/HTTP status over long `rollout status`/`--wait` blocks. If something is not healthy within the short window, report what is broken instead of waiting.

```bash
# Deploy in strict order (namespaces → operators → secrets → deps → Keycloak → apps)
kubectl apply -f dependencies/00-namespaces.yaml
# install operators once per cluster (helm commands are in the README and file headers)
kubectl apply -f dependencies/01-secrets.yaml        # local, gitignored
kubectl apply -f apps/01-secrets.yaml                # local, gitignored
kubectl apply -f dependencies/02-postgres.yaml
kubectl apply -f dependencies/03-mongo.yaml
kubectl apply -f dependencies/04-kafka.yaml
kubectl apply -f dependencies/05-grafana.yaml
kubectl apply -f apps/02-keycloak.yaml && kubectl rollout status deployment/keycloak
kubectl apply -f apps/03-spring-reactive-template.yaml
kubectl apply -f apps/04-spring-reactive-r2dbc.yaml
kubectl apply -f apps/05-react-typescript-template.yaml

# Verify (repeat -n does not query multiple namespaces; run one per namespace)
kubectl get pods -n postgres && kubectl get pods -n mongo && kubectl get pods -n kafka && kubectl get pods -n grafana
kubectl rollout status deployment/spring-reactive-r2dbc
kubectl rollout status deployment/spring-reactive-mongo
kubectl rollout status deployment/react-typescript-template
```

Offline syntax check without a cluster (safe, verified):

```bash
kubectl create --dry-run=client --validate=false -o name -f <file.yaml>
```

### Graceful cluster shutdown (Ansible, run from the dev machine)

The cluster runs on Proxmox VMs (`kube-0.lan` master + `kube-1..3.lan` workers) that are only powered on when needed. To stop everything without k8s/Rancher/Longhorn errors on next boot:

```bash
ansible-playbook -i ansible/inventory.ini ansible/shutdown-cluster.yml
# options: --skip-tags backup (no Keycloak backup) | --tags workers (keep master up)
```

It runs in the only safe order: Keycloak backup (while all pods still run — CNPG primary may live on a worker) → `shutdown -h` workers (all at once — each guest still stops k3s/Longhorn/CNPG gracefully via systemd; the verify play below is what actually waits for power-off) → `shutdown -h` master → Proxmox-API verification that every `vm-kube-*` reached `status=stopped` (uses `pve_host`/`pve.yml`; skip with `--skip-tags verify`). Backups are fetched into `keycloak-realm/<host>/`. Requirements: passwordless SSH + sudo to the VMs (already set up). On next power-on, verify with the checks above; if `/external` returns `FALLBACK`, run `scripts/fix-keycloak-service-clients.sh`.

**Verified end-to-end 2026-11-07** (real run): full shutdown completed in ~5 min; guests take 1–3 min per node after SSH drops (k3s/Longhorn stop-timeout), so the Proxmox verify play is the true completion signal. Gotchas found + fixed during that run: `wait_for` must be `delegate_to: localhost` + `become: false` (SSH to a dying guest is refused, and controller sudo doesn't exist); this PVE build has no `type` field under `/nodes/<n>/qemu`.

**The shutdown/startup playbooks are non-destructive** — they only stop/start VMs and wait; nothing in the cluster is created, deleted, or reset. `update-os.yml` installs package upgrades on the guests (rolling, master last) but changes no cluster resources.

### Cluster startup (Ansible, run from the dev machine)

```bash
# Proxmox host (p0b.lan) is set in ansible/inventory.ini; credentials go in
# ansible/group_vars/all/pve.yml (copy pve.yml.template — gitignored, needs
# pve_user + pve_password). Then:
ansible-playbook -i ansible/inventory.ini ansible/startup-cluster.yml
# without credentials the power-on tasks skip — start the VMs in the Proxmox UI
# first and the playbook just waits for everything up (-e pve_host='' disables it)
```

Tested on the live cluster: everything from the SSH wait onward (all waits, `/external` check, URL report) passed with the VMs already running. Proxmox power-on (`p0b.lan`, PVE 9.2, single node `p0b`, VMs `vm-kube-0..3` = vmid 500–503) is wired with **username/password ticket auth** (root@pam cannot use API tokens without privilege separation; API calls go through `curl` because the Homebrew Python is blocked by the macOS firewall — system Python works). Ticket + node/VM listing verified read-only; the `status/start` call itself is only exercised on a real VM-off→on cycle. Credentials live in gitignored `ansible/group_vars/all/pve.yml` (template committed). Note: this PVE build returns 501 for `/api2/json/resources` — use `/nodes` + `/nodes/<n>/qemu` instead.

It waits through: SSH on all nodes → 4 nodes Ready → Longhorn volumes scheduled → CNPG clusters healthy → Kafka/Mongo/Grafana Running → app deployments 1/1 → `/external` check **with auto-heal** (runs `scripts/fix-keycloak-service-clients.sh` on its own if the answer is `FALLBACK`) → final URL check + report. End state when it prints `ok`: everything is serving.

Known startup gotcha unrelated to the playbook: long downtimes expire certificates (LE certs auto-renew within minutes via cert-manager; k3s admin + Linkerd certs need the rotations documented in this file if pods report expired-certificate errors).

Cleanup is destructive (`kubectl delete -f ...` in reverse order — see README "Cleanup"); back up data first.

### OS updates on the VMs (Ansible, run from the dev machine)

```bash
ansible-playbook -i ansible/inventory.ini ansible/update-os.yml
# dry run (no changes/reboots, shows pending counts): --check
# one node only: -l kube-1.lan
```

`apt full-upgrade` on ALL nodes in parallel (user preference: speed over availability). **Reboot is off by default** — pending kernel/critical updates are installed but nodes are NOT rebooted (the playbook reports the pending reboot instead); pass `-e reboot_after_update=true` to reboot the nodes that need it (all simultaneously → ~2–3 min full outage, then it waits for the k3s service + `kubectl wait node/vm-kube-N Ready`). A pre-task waits out any orphaned apt/dpkg from killed runs, so re-running is safe. Non-destructive; no cluster-resource changes.

### Cluster component upgrades (Ansible, run from the dev machine)

```bash
ansible-playbook -i ansible/inventory.ini ansible/update-cluster.yml
ansible-playbook -i ansible/inventory.ini ansible/update-cluster.yml --tags report   # read-only version report
# single component: --tags rancher | longhorn | k3s | linkerd
```

Upgrades Rancher → Longhorn → k3s → Linkerd (order per official docs, researched 2026-11-07). **No version numbers are ever provided** — paths are computed at runtime: installed version from `helm list`, targets from `helm search repo --versions` (officially documented discovery), stepped latest-patch-per-minor by `ansible/files/stepwise-path.py` (both Rancher and Longhorn require one-minor hops; Longhorn's pre-upgrade job hard-blocks skipping). k3s needs no version at all — the SUC plans poll the stable CHANNEL URL and upgrade themselves; the playbook only waits for convergence. Linkerd uses the always-latest CLI + `linkerd upgrade` (retains cluster config/TLS), channel auto-detected (edge stays edge). Optional overrides: `-e rancher_max_minor=2.14`, `-e k3s_version=vX.Y.Z+k3sN` (pin plans instead of channel).

- **Rancher**: stepwise, latest patch chart per minor — path computed from the repo, current minor to newest. Skipping minors is unsupported (docs statement; no chart-side enforcement). SUSE guidance: Rancher before Kubernetes. Values preserved via `--reuse-values` + the three `--set` flags from dev-infra's rancher README.
- **Longhorn**: one minor at a time, path computed from the repo — the chart's pre-upgrade job hard-blocks skipping; volumes must be healthy (preflight check); engines live-upgraded per step (`longhorn_live_upgrade: true`; set false to do it via UI).
- **k3s**: existing system-upgrade-controller plans track the stable channel (server → agents, cordon, concurrency 1). The playbook only verifies plans exist and waits for all nodes on one identical version + Ready — a no-op when the channel matches the installed build.
- **Linkerd**: stays on **edge** (stable 2.20's k8s ceiling < k3s 1.37). Installs latest edge CLI on the master, `linkerd upgrade --crds` + `linkerd upgrade` (retains cluster TLS/config), re-installs viz through the same `sed` that sets the customized `-enforced-host=.*$`, prunes, restarts meshed deployments in `default`, then `linkerd check --proxy`.
- Pre-step: Keycloak backup (`--skip-tags backup` to omit). Take a k3s snapshot first for real runs: `sudo k3s etcd-snapshot save` on the master.

Verified: syntax + full `--check` dry run + live version report. As of 2026-11-07 the components are outdated — Rancher v2.13.3 (latest 2.15.3), Longhorn v1.11.1 (latest 1.13.0), Linkerd edge-26.3.3 (latest edge ~26.11), k3s v1.37.2+k3s1 = latest stable (no-op). ⚠️ k3s 1.37 is above the certified Kubernetes ceiling of every released Rancher (2.15.x supports ≤1.36) — works, but outside the support matrix until Rancher 2.16.

## Gotchas

- **Kafka topic naming**: K8s resource names can't contain underscores, so `KafkaTopic` `metadata.name` uses hyphens and `spec.topicName` carries the real name (e.g. `sample-topic-2` → `sample_topic_2`). Keep both in sync when editing.
- **CNPG services**: connect writes/migrations to `<cluster>-rw.<ns>.svc:5432`, reads to `-ro`; `-rw` always points at the primary.
- **Images**: app images use `:latest` tags (`xcodeassociated/*`); grafana is pinned (`grafana/otel-lgtm:0.22.1`) — update deliberately. Keycloak uses a custom `xcodeassociated/keycloak-kafka:latest` image that emits events to Kafka topics `keycloak-events` / `keycloak-admin-events`.
- **OTLP export is kill-switched in the app Deployments (not the repo manifests)**: `env` entries `OTEL_SDK_DISABLED=true`, `MANAGEMENT_*_OTLP_ENABLED=false`, `SPRING_AUTOCONFIGURE_EXCLUDE=<3 otel autoconfigs>` on `spring-reactive-mongo` + `spring-reactive-r2dbc`. Reason: the current `:latest` images have a broken otel classpath — enabling export crashes pods instantly with `ClassNotFoundException: io.opentelemetry.api.incubator.common.ExtendedAttributeKey` (verified 2026-11-07 by removing the switches → CrashLoopBackOff). Consequence: **no logs in Loki, no traces in Tempo drilldown** — expected, not a cluster bug. Metrics in otel.softeno.dev come from the lgtm stack's Prometheus *scraping*, not OTLP. App logs DO carry trace IDs locally (`[traceId] [spanId]` pattern) — they just aren't exported. Fix path: rebuild the backend images with a consistent `opentelemetry-*` dependency set (api-incubator missing / version skew), then delete the 7 env entries (`kubectl -n default set env deploy/<d> OTEL_SDK_DISABLED- MANAGEMENT_...-` + remove the exclude) and restart. Same classpath issue causes `/external/grpc` 500s.
- **Prereqs assumed present, not defined here**: cert-manager with a `ClusterIssuer` named `acme-issuer`, an nginx ingress controller, Linkerd (all app pods carry `linkerd.io/inject: enabled`), the `longhorn` StorageClass, and DNS/`/etc/hosts` entries for `*.softeno.dev` (see comments in `apps/03-spring-reactive-template.yaml`).
- **Optional features are removable by design**: each feature is one numbered file wired into apps only via commented ConfigMap sections (`# ── Kafka ──…`, `# ── Observability ──…`) and secret keys. When removing or adding a feature, delete/edit the file **and** the matching app ConfigMap sections + secret entries (recipes in README "Removing optional features").
- Keycloak runs `KC_PROXY: edge` with hostname `https://auth.softeno.dev`; the realm and OAuth clients must be created manually after startup, and generated client secrets must be copied into `apps/01-secrets.yaml`.
- App ConfigMaps wire inter-service calls on the assumption both Spring apps are in `default`.

## Maintaining the docs

**Both `README.md` and `AGENTS.md` must always be kept up to date.** After finishing development work, and before handing off, check the change against both files and update them in the same task if affected:

- `README.md` — features, project structure, optional-feature removal, prerequisites, deploy/cleanup order, endpoints, secret relationships.
- `AGENTS.md` — commands and verification, layout, namespaces, secret cross-references, prerequisites, gotchas (ports, image tags, Kafka topic naming, Linkerd/ingress annotations).

Never hand off changes that leave either doc stale. Prefer verified commands; label anything untested.
