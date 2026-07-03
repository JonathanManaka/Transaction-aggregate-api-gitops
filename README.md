# Transaction Aggregate API — GitOps Stack

Everything needed to run the **transac-agg-api** service and its supporting
infrastructure (PostgreSQL, Temporal, Prometheus, Grafana) on a local
Kubernetes cluster, managed by **ArgoCD**.

Deployment is **GitOps**: ArgoCD watches this repo's `main` branch and syncs the
cluster to match. You don't `kubectl apply` app manifests by hand — you push to
`main` and ArgoCD reconciles.

---

## Architecture

```
                 ┌─────────────────────────── ArgoCD (ns: argocd) ───────────────────────────┐
                 │  watches this repo @ main, auto-syncs (prune + selfHeal)                    │
                 └───────┬───────────────┬───────────────┬───────────────┬────────────────────┘
                         │               │               │               │
                    Application     Application     Application     Application
                  transac-agg-api    prometheus        grafana        temporal
                    path: k8s/      path: k8s/       path: k8s/      path: k8s/
                   (kustomize)      prometheus        grafana         temporal
                         │            (helm)           (helm)          (helm)
                         ▼               ▼               ▼               ▼
   ┌───────────────────────────────── namespace: dev ─────────────────────────────────┐
   │  transac-agg-api ──JDBC──▶ postgres          prometheus ◀──scrape── transac-agg-api │
   │  (Spring Boot)            (PVC, db=transac_aggr)   │                                 │
   │        │                                           └──datasource──▶ grafana         │
   │        └──Temporal──▶ temporal-frontend:7233                                         │
   └───────────────────────────────────────────────────────────────────────────────────┘
```

All services run in the **`dev`** namespace and are reachable on `localhost` via
NodePorts (single-node local cluster).

| Component        | Deployed via         | URL / endpoint                          | NodePort |
|------------------|----------------------|-----------------------------------------|----------|
| ArgoCD UI        | helmfile             | http://localhost:30443                  | 30443    |
| transac-agg-api  | kustomize (`k8s/`)   | http://localhost:30080                  | 30080    |
| PostgreSQL       | kustomize (`k8s/`)   | `localhost:30543` (db `transac_aggr`)   | 30543    |
| Prometheus       | Helm                 | http://localhost:30090                  | 30090    |
| Grafana          | Helm                 | http://localhost:30300                  | 30300    |
| Temporal         | Helm                 | `temporal-frontend:7233` (in-cluster)   | —        |

---

## Prerequisites

- A local Kubernetes cluster. On this machine that's **Rancher Desktop**:

- `kubectl` (pointed at the local cluster: `kubectl config current-context`)
- `helm` and [`helmfile`](https://github.com/helmfile/helmfile)
- `kubeseal` (only if you need to (re)create sealed secrets)
- Cluster egress to the public internet — Grafana's init container pulls
  dashboards from `grafana.com`, and Helm charts pull from their repos.

---

## Bring it all up

### 1. Point kubectl at the local cluster
```bash
kubectl config current-context     # should be your local cluster (e.g. rancher-desktop)
```

### 2. Install the Sealed Secrets controller  *(required first — the repo ships SealedSecret resources)*
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system \
  --set fullnameOverride=sealed-secrets-controller
```
> The `SealedSecret` objects in `k8s/` are decrypted by **this** controller's
> private key. If the controller's key differs from the one used to seal them,
> the secrets won't unseal — you'll need to re-seal (see **Secrets** below).

### 5. Register the applications
```bash
kubectl apply -f gitops/argocd/deployment.yml \
              -f gitops/argocd/prometheus.yml \
              -f gitops/argocd/grafana.yml \
              -f gitops/argocd/temporal.yml
```
ArgoCD now syncs each app from **`main`** automatically (`prune` + `selfHeal`).

### 6. Watch it converge
```bash
kubectl get applications -n argocd
# wait until every app shows: SYNCED / Healthy
kubectl get pods -n dev -w
```

That's it. Because sync is automated, **future changes go live by committing and
pushing to `main`** — not by editing the cluster.

---

## Verify

**App is up**
```bash
curl http://localhost:30080/health
curl http://localhost:30080/actuator/prometheus | head   # metrics Prometheus scrapes
```

**Prometheus** — http://localhost:30090 → *Status → Targets* (the app should be `UP`).

**Grafana** — http://localhost:30300 → **Dashboards** (General folder):
*JVM (Micrometer)*, *Node Exporter Full*, *Prometheus 2.0 Overview*.
Login is `admin` / the `grafana-admin-password` key in the `grafana-secret`.

---

## Secrets

Two credentials are stored as **SealedSecrets** (encrypted, safe to commit) and
decrypted in-cluster by the sealed-secrets controller:

| SealedSecret file                | Creates secret          | Used by            | Key                     |
|----------------------------------|-------------------------|--------------------|-------------------------|
| `k8s/postgres/sealed-secret.yaml`| `transac-agg-api-secret`| postgres **and** app | `POSTGRES_PASSWORD`   |
| `k8s/grafana/sealed-secret.yaml` | `grafana-secret`        | grafana            | `grafana-admin-password`|

> **One shared DB secret.** `transac-agg-api-secret` is consumed by *both* the
> Postgres deployment (to set the DB password) and the app (to connect). Keep it
> a single SealedSecret — don't create a second one with the same name, or
> `kustomize build` fails with `already registered id`.

**To (re)seal a secret** for this cluster's controller:
```bash
kubectl create secret generic transac-agg-api-secret -n dev \
  --from-literal=POSTGRES_PASSWORD='<new-password>' \
  --dry-run=client -o yaml \
| kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system \
           --format yaml \
> k8s/postgres/sealed-secret.yaml
# commit + push → ArgoCD applies it
```

---

## Troubleshooting

**Grafana dashboards are empty.**
The dashboards are provisioned in `k8s/grafana/values.yaml` and downloaded by an
init container at pod start. If they're missing:
- Confirm the change is on **`main`** (ArgoCD tracks `HEAD`/main, not feature branches).
- Confirm the pod has the init container:
  `kubectl get deploy grafana -n dev -o jsonpath='{.spec.template.spec.initContainers[*].name}'`
  → should list `download-dashboards`. If empty, the deployed values have no
  `dashboards:` block (change isn't live).
- Check the download succeeded (needs egress to grafana.com):
  `kubectl logs -n dev deploy/grafana -c download-dashboards`

**Postgres: `password authentication failed for user "postgres"`.**
Postgres applies `POSTGRES_PASSWORD` **only on first init of an empty data dir**.
Because it uses a PVC (`postgres-pvc`), changing the secret later does **not**
change the existing DB's password. Either reset the password to match the secret
(keeps data):
```bash
PW=$(kubectl get secret transac-agg-api-secret -n dev -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
kubectl exec -n dev deploy/postgres -c postgres -- psql -U postgres -c "ALTER USER postgres WITH PASSWORD '$PW';"
```
…or wipe the volume to re-init from the secret (**deletes all DB data**):
```bash
kubectl scale deploy/postgres -n dev --replicas=0
kubectl delete pvc postgres-pvc -n dev
kubectl scale deploy/postgres -n dev --replicas=1
```

**`secret "grafana-secret" not found`.**
The sealed-secrets controller either isn't installed (step 2) or can't unseal
with its current key — re-seal `k8s/grafana/sealed-secret.yaml` against this
cluster's controller and push.

---