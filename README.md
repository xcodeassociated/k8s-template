# Kubernetes template stack for the template services

Kubernetes manifests for deploying the companion template services in a small
production-like cluster. This directory is also a template: copy it, rename
resources/domains/images, adjust sizing, and replace the secret workflow before
using it for a real application.

Shared dependencies included here:

- **PostgreSQL** via CloudNativePG
- **MongoDB** via MongoDB Community Operator
- **Kafka** via Strimzi
- **Grafana OTEL-LGTM** for observability
- **Keycloak** for auth

Template services served by this stack:

- [spring-reactive-template](https://github.com/xcodeassociated/spring-reactive-template) — Spring reactive Mongo/Kafka template
- [spring-reactive-r2dbc-template](https://github.com/xcodeassociated/spring-reactive-r2dbc-template) — Spring reactive R2DBC/PostgreSQL/Kafka template
- [react-typescript-vite-template](https://github.com/xcodeassociated/react-typescript-vite-template) — React + TypeScript + Vite frontend template

> This directory is intended to be public-repo safe. Commit templates and
> manifests only; never commit real credentials, kubeconfigs, private keys, or
> generated secret files.

## Layout

```text
.
├── dependencies/
│   ├── 00-namespaces.yaml
│   ├── postgres.yaml
│   ├── mongo.yaml
│   ├── kafka.yaml
│   └── grafana.yaml
├── secrets.template.yaml   # committed placeholders only
├── secrets.yaml            # local/private, ignored by git
├── keycloak.yaml
├── spring-reactive-r2dbc.yaml
├── spring-reactive-template.yaml
└── react-typescript-template.yaml
```

## Prerequisites

- A Kubernetes cluster and a `kubectl` context pointing at the target cluster.
- `helm` available for installing operators.
- A default `StorageClass` or the `longhorn` `StorageClass` used by these manifests.
- `cert-manager`, an nginx ingress controller, and working DNS for the configured hosts.
- Replace example image names, domains, and resource sizes before using this outside a lab.

If ACME certificates do not issue, make sure public DNS reaches the ingress and
remove local/router DNS overrides that intercept the validation hostnames.

## Setup order

Namespaced secrets cannot be created until their namespaces exist, and database
operators must be installed before their custom resources are applied. Use this
order:

```text
1. namespaces
2. operators / CRDs
3. secrets
4. dependency custom resources
5. Keycloak
6. applications
```

### 1. Create namespaces

```bash
kubectl apply -f dependencies/00-namespaces.yaml
```

### 2. Install dependency operators

Install the operators once per cluster. The dependency manifests contain the
same reminder commands in comments.

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

Verify the operators are running:

```bash
kubectl get pods -n postgres
kubectl get pods -n mongo
kubectl get pods -n kafka
```

### 3. Create private secrets

Copy the template and fill in real values locally:

```bash
cp secrets.template.yaml secrets.yaml
```

Required value relationships:

- `mongodb-admin-password.password` must match `spring-reactive-mongo-secret.MONGO_PASSWORD`.
- `postgres-app-credentials.password` must match `spring-reactive-r2dbc-secret.SPRING_R2DBC_PASSWORD` and `SPRING_LIQUIBASE_PASSWORD`.
- `postgres-keycloak-credentials.password` must match `secret-keycloak.KC_DB_PASSWORD`.
- OAuth client secrets must match the clients configured in Keycloak.

Apply the local secret file:

```bash
kubectl apply -f secrets.yaml
```

`secrets.yaml` is intentionally ignored by git. For production GitOps, replace
this manual file with External Secrets, SOPS, or Sealed Secrets.

### 4. Deploy dependencies

```bash
kubectl apply -f dependencies/postgres.yaml
kubectl apply -f dependencies/mongo.yaml
kubectl apply -f dependencies/kafka.yaml
kubectl apply -f dependencies/grafana.yaml
```

Watch readiness:

```bash
kubectl get pods -n postgres
kubectl get pods -n mongo
kubectl get pods -n kafka
kubectl get pods -n grafana
```

### 5. Deploy Keycloak

```bash
kubectl apply -f keycloak.yaml
kubectl rollout status deployment/keycloak
```

After Keycloak is ready, create the required realm and OAuth clients, then update
`secrets.yaml` if any generated client secrets changed.

### 6. Deploy applications

```bash
kubectl apply -f spring-reactive-r2dbc.yaml
kubectl apply -f spring-reactive-template.yaml
kubectl apply -f react-typescript-template.yaml

kubectl rollout status deployment/spring-reactive-r2dbc
kubectl rollout status deployment/spring-reactive-mongo
kubectl rollout status deployment/react-typescript-template
```

## Cleanup

Cleanup is destructive. Back up any data you need before deleting databases,
Kafka volumes, namespaces, or PVCs.

Delete application resources first:

```bash
kubectl delete -f react-typescript-template.yaml --ignore-not-found
kubectl delete -f spring-reactive-template.yaml --ignore-not-found
kubectl delete -f spring-reactive-r2dbc.yaml --ignore-not-found
kubectl delete -f keycloak.yaml --ignore-not-found
```

Delete dependency resources and private secrets:

```bash
kubectl delete -f dependencies/grafana.yaml --ignore-not-found
kubectl delete -f dependencies/kafka.yaml --ignore-not-found
kubectl delete -f dependencies/mongo.yaml --ignore-not-found
kubectl delete -f dependencies/postgres.yaml --ignore-not-found
kubectl delete -f secrets.yaml --ignore-not-found
```

Optionally uninstall operators if nothing else uses them:

```bash
helm uninstall strimzi-operator -n kafka || true
helm uninstall mongodb-community-operator -n mongo || true
helm uninstall cnpg -n postgres || true
```

Finally, delete the namespaces:

```bash
kubectl delete -f dependencies/00-namespaces.yaml --ignore-not-found
```

If persistent volumes remain because a storage class or operator retained them,
inspect them before deletion:

```bash
kubectl get pvc -A
kubectl get pv
```

## Public repository checklist

- Keep `secrets.template.yaml` placeholders only.
- Keep `secrets.yaml` ignored and local/private.
- Do not commit kubeconfigs, certificates with private keys, tokens, or `.env` files.
- Run a secret scan before publishing the repository.
- Review hard-coded domains, image names, storage sizes, and ingress settings.
