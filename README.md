# Kubernetes service template

A **template stack for starting new applications**: production-like Kubernetes
manifests with fully wired shared dependencies — Keycloak auth, Kafka,
PostgreSQL, MongoDB, and OTel observability — so you can spend your time on
your service, not on infrastructure setup. Use it to **prototype and validate
ideas fast**: apply the stack, drop in your own Deployment/Service/Ingress
bundle, and you have authentication, messaging, databases, TLS, storage, and
dashboards working on day one.

This directory is a template, not a product. Copy it, rename
resources/domains/images, **remove the features you do not need**, and replace
the secret workflow before using it for a real application.

> Intended to be public-repo safe. Commit templates and manifests only; never
> commit real credentials, kubeconfigs, private keys, or generated secret files.

## Served template services

- [spring-reactive-template](https://github.com/xcodeassociated/spring-reactive-template) — Spring reactive + MongoDB + Kafka (WebSocket, gRPC)
- [spring-reactive-r2dbc-template](https://github.com/xcodeassociated/spring-reactive-r2dbc-template) — Spring reactive + R2DBC/PostgreSQL + Kafka (Liquibase, GraphQL, gRPC)
- [react-typescript-vite-template](https://github.com/xcodeassociated/react-typescript-vite-template) — React + TypeScript + Vite frontend

## Features

Every feature lives in its own numbered, self-contained manifest file and is
wired into the applications only through clearly commented `ConfigMap` sections
and secret entries, so **anything you do not want is easy to remove** (see
"Removing optional features").

| Feature | Stack | Manifest | Optional |
| --- | --- | --- | --- |
| Authentication / SSO | Keycloak (custom image with Kafka event emission), PostgreSQL-backed, realm `app`, OAuth2 clients | `apps/02-keycloak.yaml` | Yes* |
| Relational database | PostgreSQL HA clusters via CloudNativePG (`postgres-app` + `postgres-keycloak`, each 1 primary + 2 replicas) | `dependencies/02-postgres.yaml` | Yes* |
| Document database | MongoDB replica set via Community Operator | `dependencies/03-mongo.yaml` | Yes |
| Event streaming | Kafka via Strimzi (controller + broker pools), topics, kafka-ui | `dependencies/04-kafka.yaml` | Yes |
| Observability | Grafana otel-lgtm (Loki + Grafana + Tempo + Mimir, all-in-one), OTLP ingest | `dependencies/05-grafana.yaml` | Yes |
| Apps (backend HTTP + gRPC, frontend SPA) | Deployment + Service + Ingress per service, actuator probes, resource limits | `apps/03…05-*.yaml` | Yes |
| TLS + ingress | nginx ingress, cert-manager ACME (`acme-issuer`); wildcard `main-certificate` + per-host `api-certificate-prod` | referenced in every Ingress | No |
| Persistent storage | `longhorn` StorageClass for all PVCs | referenced in dependency manifests | No |
| Service mesh | Linkerd sidecar injection (`linkerd.io/inject: enabled` pod annotation) | pod templates in `apps/` | Yes |

\* Keycloak is required by the Spring app templates as shipped (OAuth2
resource-server config); Postgres is required by the R2DBC template and by
Keycloak. Remove them together with the features that reference them.

## Project structure

```text
.
├── dependencies/
│   ├── 00-namespaces.yaml           # kafka, postgres, mongo, grafana namespaces
│   ├── 01-secrets.template.yaml     # committed placeholders only
│   ├── 01-secrets.yaml              # local/private, ignored by git
│   ├── 02-postgres.yaml             # CNPG clusters: postgres-app, postgres-keycloak
│   ├── 03-mongo.yaml                # MongoDBCommunity mongodb-rs
│   ├── 04-kafka.yaml                # Strimzi Kafka, topics, metrics, kafka-ui
│   └── 05-grafana.yaml              # otel-lgtm observability stack
└── apps/                            # all deployed into the default namespace
    ├── 01-secrets.template.yaml     # committed placeholders only
    ├── 01-secrets.yaml              # local/private, ignored by git
    ├── 02-keycloak.yaml             # Keycloak + ConfigMap + Service + Ingress
    ├── 03-spring-reactive-template.yaml     # deployment "spring-reactive-mongo"
    ├── 04-spring-reactive-r2dbc.yaml        # deployment "spring-reactive-r2dbc"
    └── 05-react-typescript-template.yaml    # frontend
```

Conventions:

- Each app file is a self-contained bundle: `ConfigMap` (non-secret config) +
  `Secret` refs via `envFrom` + `Deployment` + `Service` + `Ingress`.
- Dependencies run in dedicated namespaces; applications run in `default`.
- The two Spring backends share the host `api.softeno.dev` and are routed by
  path prefix (`/spring-reactive-template/…`, `/spring-reactive-r2dbc-template/…`);
  they also call each other over in-cluster REST and gRPC as a demo of
  service-to-service auth.
- Endpoints: `app.softeno.dev` + `www.app.softeno.dev` (frontend),
  `auth.softeno.dev` (Keycloak), `kafka.softeno.dev` (kafka-ui),
  `otel.softeno.dev` (Grafana, LAN-restricted).

## Removing optional features

Because features are isolated in single files and commented ConfigMap sections:

1. Delete the numbered manifest file (e.g. `dependencies/05-grafana.yaml`).
2. In the app manifests, remove the matching `ConfigMap` section (the blocks
   are labeled `# ── Kafka ──…`, `# ── Observability ──…`, etc.) and the related
   keys in `apps/01-secrets*.yaml`.
3. Remove cross-references: OAuth/`OAUTH_*`/`SPRING_SECURITY_OAUTH2_*` keys when
   dropping Keycloak, `KAFKA_*`/topic definitions when dropping Kafka,
   `MONGO_*`/`SPRING_R2DBC_*` when dropping a database, and the inter-service
   URLs if you keep only one backend.
4. Delete the corresponding secret cross-dependencies (see "Secrets" below),
   e.g. `secret-keycloak` and `postgres-keycloak-credentials` go with Keycloak.

To keep only one backend template, delete its file plus the other backend's
inter-service references, then apply everything as usual. To add **your**
service, copy `apps/03-spring-reactive-template.yaml` as a starting skeleton and
rename the resources, image, hosts, and paths.

## Prerequisites

- A Kubernetes cluster and a `kubectl` context pointing at the target cluster.
- `helm` for installing the operators (CloudNativePG, MongoDB Community, Strimzi).
- `cert-manager` with a `ClusterIssuer` named `acme-issuer`, an nginx ingress
  controller, and **Linkerd** (app pods request sidecar injection).
- The `longhorn` StorageClass (or edit the manifests to use your default).
- Working DNS for the `*.softeno.dev` hosts (see `/etc/hosts` hints in the
  app manifests for local use).
- Replace example image names, domains, and resource sizes before using this
  outside a lab. If ACME certificates do not issue, make sure public DNS
  reaches the ingress and remove local/router DNS overrides intercepting the
  validation hostnames.

## Setup order

Namespaced secrets cannot be created before their namespaces, and operators
must exist before their custom resources. Use this order:

```text
1. namespaces → 2. operators/CRDs → 3. secrets → 4. dependency CRs
→ 5. Keycloak → 6. applications
```

### 1. Create namespaces

```bash
kubectl apply -f dependencies/00-namespaces.yaml
```

### 2. Install dependency operators (once per cluster)

```bash
# CloudNativePG
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg --namespace postgres

# MongoDB Community Operator
helm repo add mongodb https://mongodb.github.io/helm-charts
helm repo update
helm upgrade --install mongodb-community-operator mongodb/community-operator \
  --namespace mongo \
  --set operator.watchNamespace=mongo

# Strimzi Kafka Operator
helm repo add strimzi https://strimzi.io/charts/
helm repo update
helm upgrade --install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --set watchNamespaces='{kafka}'
```

Verify:

```bash
kubectl get pods -n postgres
kubectl get pods -n mongo
kubectl get pods -n kafka
```

### 3. Create private secrets

```bash
cp dependencies/01-secrets.template.yaml dependencies/01-secrets.yaml
cp apps/01-secrets.template.yaml apps/01-secrets.yaml
# edit both files with real values
kubectl apply -f dependencies/01-secrets.yaml
kubectl apply -f apps/01-secrets.yaml
```

Required value relationships:

- `mongodb-admin-password.password` = `spring-reactive-mongo-secret.MONGO_PASSWORD`
- `postgres-app-credentials.password` = `spring-reactive-r2dbc-secret.SPRING_R2DBC_PASSWORD` = `SPRING_LIQUIBASE_PASSWORD`
- `postgres-keycloak-credentials.password` = `secret-keycloak.KC_DB_PASSWORD`
- OAuth client secrets must match the clients configured in Keycloak.

Local `**/*secrets.yaml` files are ignored by git; `*.template.yaml` files hold
placeholders only. For production GitOps, replace this manual workflow with
External Secrets, SOPS, or Sealed Secrets.

### 4. Deploy dependencies

```bash
kubectl apply -f dependencies/02-postgres.yaml
kubectl apply -f dependencies/03-mongo.yaml
kubectl apply -f dependencies/04-kafka.yaml
kubectl apply -f dependencies/05-grafana.yaml
kubectl get pods -n postgres
kubectl get pods -n mongo
kubectl get pods -n kafka
kubectl get pods -n grafana
```

### 5. Deploy Keycloak

```bash
kubectl apply -f apps/02-keycloak.yaml
kubectl rollout status deployment/keycloak
```

Create the `app` realm and the OAuth clients referenced by the app ConfigMaps
(`backend`, `backend2`, plus any the frontend needs), then update the local
secret files if client secrets changed.

### 6. Deploy applications

```bash
kubectl apply -f apps/03-spring-reactive-template.yaml
kubectl apply -f apps/04-spring-reactive-r2dbc.yaml
kubectl apply -f apps/05-react-typescript-template.yaml

kubectl rollout status deployment/spring-reactive-mongo
kubectl rollout status deployment/spring-reactive-r2dbc
kubectl rollout status deployment/react-typescript-template
```

## Cleanup

Cleanup is destructive — back up data before deleting databases, Kafka volumes,
namespaces, or PVCs. Delete in reverse order:

```bash
kubectl delete -f apps/05-react-typescript-template.yaml --ignore-not-found
kubectl delete -f apps/04-spring-reactive-r2dbc.yaml --ignore-not-found
kubectl delete -f apps/03-spring-reactive-template.yaml --ignore-not-found
kubectl delete -f apps/02-keycloak.yaml --ignore-not-found
kubectl delete -f dependencies/05-grafana.yaml --ignore-not-found
kubectl delete -f dependencies/04-kafka.yaml --ignore-not-found
kubectl delete -f dependencies/03-mongo.yaml --ignore-not-found
kubectl delete -f dependencies/02-postgres.yaml --ignore-not-found
kubectl delete -f apps/01-secrets.yaml --ignore-not-found
kubectl delete -f dependencies/01-secrets.yaml --ignore-not-found
```

Optionally uninstall operators if nothing else uses them:

```bash
helm uninstall strimzi-operator -n kafka || true
helm uninstall mongodb-community-operator -n mongo || true
helm uninstall cnpg -n postgres || true
```

Finally delete namespaces (`kubectl delete -f dependencies/00-namespaces.yaml`)
and inspect leftover volumes with `kubectl get pvc -A && kubectl get pv`.

## Public repository checklist

- Keep `dependencies/01-secrets.template.yaml` and `apps/01-secrets.template.yaml` placeholders only.
- Keep local `**/*secrets.yaml` files ignored and private.
- Do not commit kubeconfigs, certificates with private keys, tokens, or `.env` files.
- Run a secret scan before publishing the repository.
- Review hard-coded domains, image names, storage sizes, and ingress settings
  (e.g. the `MONGO_DB: "admin"` placeholder in `apps/03-spring-reactive-template.yaml`).
