# AGENTS.md

Guidance for coding agents working in this repository.

## What this repo is

A **template Kubernetes manifest stack** (plain YAML, no application source, no build system, no CI) for deploying three companion template services in a small production-like cluster:

- `spring-reactive-mongo` — [spring-reactive-template](https://github.com/xcodeassociated/spring-reactive-template) (Spring reactive + MongoDB + Kafka)
- `spring-reactive-r2dbc` — [spring-reactive-r2dbc-template](https://github.com/xcodeassociated/spring-reactive-r2dbc-template) (Spring reactive + R2DBC/PostgreSQL + Kafka)
- `react-typescript-template` — [react-typescript-vite-template](https://github.com/xcodeassociated/react-typescript-vite-template) frontend

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
- For production GitOps, replace this manual workflow with External Secrets, SOPS, or Sealed Secrets.

## Commands

There is no build, test, or lint step. Work is validated against a cluster with `kubectl` (context must point at the target cluster):

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

Cleanup is destructive (`kubectl delete -f ...` in reverse order — see README "Cleanup"); back up data first.

## Gotchas

- **Kafka topic naming**: K8s resource names can't contain underscores, so `KafkaTopic` `metadata.name` uses hyphens and `spec.topicName` carries the real name (e.g. `sample-topic-2` → `sample_topic_2`). Keep both in sync when editing.
- **CNPG services**: connect writes/migrations to `<cluster>-rw.<ns>.svc:5432`, reads to `-ro`; `-rw` always points at the primary.
- **Images**: app images use `:latest` tags (`xcodeassociated/*`); grafana is pinned (`grafana/otel-lgtm:0.22.1`) — update deliberately. Keycloak uses a custom `xcodeassociated/keycloak-kafka:latest` image that emits events to Kafka topics `keycloak-events` / `keycloak-admin-events`.
- **Prereqs assumed present, not defined here**: cert-manager with a `ClusterIssuer` named `acme-issuer`, an nginx ingress controller, Linkerd (all app pods carry `linkerd.io/inject: enabled`), the `longhorn` StorageClass, and DNS/`/etc/hosts` entries for `*.softeno.dev` (see comments in `apps/03-spring-reactive-template.yaml`).
- **Optional features are removable by design**: each feature is one numbered file wired into apps only via commented ConfigMap sections (`# ── Kafka ──…`, `# ── Observability ──…`) and secret keys. When removing or adding a feature, delete/edit the file **and** the matching app ConfigMap sections + secret entries (recipes in README "Removing optional features").
- Keycloak runs `KC_PROXY: edge` with hostname `https://auth.softeno.dev`; the realm and OAuth clients must be created manually after startup, and generated client secrets must be copied into `apps/01-secrets.yaml`.
- App ConfigMaps wire inter-service calls on the assumption both Spring apps are in `default`.

## Maintaining the docs

**`README.md` must always be kept up to date.** After finishing development work, check whether the change affects the README (features, structure, optional-feature removal, prerequisites, deploy/cleanup order, endpoints, secret relationships) and update it in the same task if so. Never hand off code changes that leave the README stale.

Update `AGENTS.md` together with `README.md` whenever namespaces, secret relationships, deploy order, hostnames, or prerequisite operators change. Prefer verified commands; label anything untested.
