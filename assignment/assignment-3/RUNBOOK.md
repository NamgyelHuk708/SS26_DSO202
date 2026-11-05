# Assignment 3 — Runbook (Kustomize + Helm)

Work through this file **top to bottom**. Every command block is meant to be
pasted as-is from `assignment/assignment-3`. Do not skip ahead: later steps
depend on earlier ones.

- 📸 **Sxx** = take a screenshot now, save it as `evidence/Sxx-<name>.png`
- 📝 = something to write down for the report (keep a scratch file open)
- ⏱ = expect a wait (Postgres runs under arm64 emulation and starts slowly)

If any command prints something different from what is described, **stop and
paste the output** before continuing.

---

## Phase 0 — Set up the folder (once)

```bash
cd ~/Desktop/SEM_7/DSO202/SS26_DSO202/assignment/assignment-3
ls   # cluster/  helm/  kustomize/  RUNBOOK.md  (after unzipping)

# Real credentials (gitignored). Change the passwords in all four files.
cp kustomize/overlays/dev/db-secret.env.example  kustomize/overlays/dev/db-secret.env
cp kustomize/overlays/prod/db-secret.env.example kustomize/overlays/prod/db-secret.env
cp helm/environments/secrets-dev.yaml.example    helm/environments/secrets-dev.yaml
cp helm/environments/secrets-prod.yaml.example   helm/environments/secrets-prod.yaml
nano kustomize/overlays/dev/db-secret.env   # both password lines must match
nano kustomize/overlays/prod/db-secret.env
nano helm/environments/secrets-dev.yaml
nano helm/environments/secrets-prod.yaml

# Host names for the four environments (all on the one NGINX controller)
grep -q kust-dev.tasks.local /etc/hosts || \
  echo "127.0.0.1 kust-dev.tasks.local kust-prod.tasks.local helm-dev.tasks.local helm-prod.tasks.local" | sudo tee -a /etc/hosts

mkdir -p evidence
git -C .. status --short -uall assignment-3 | grep -E 'db-secret\.env$|secrets-(dev|prod)\.yaml$' \
  && echo "!! a secret file is visible to git" || echo "secrets are gitignored"
```

Health check before starting (same as every morning):

```bash
kubectl config use-context kind-dso202-a3
kubectl get nodes
kubectl get pods -n ingress-nginx -o wide
curl -si http://localhost:30080 | head -1          # HTTP/1.1 404 Not Found
docker info --format 'Docker VM memory: {{.MemTotal}}  CPUs: {{.NCPU}}'
```

📸 **S00-environment** — nodes Ready, controller on control-plane, the 404, tool versions:
```bash
kind version; kubectl version --client | head -2; helm version --short
```

---

## Phase 1 — Kustomize

### K1. Render without touching the cluster (“rendered YAML is the truth”)

```bash
kubectl kustomize kustomize/base           > evidence/K1-render-base.yaml
kubectl kustomize kustomize/overlays/dev   > evidence/K1-render-dev.yaml
kubectl kustomize kustomize/overlays/prod  > evidence/K1-render-prod.yaml
for f in base dev prod; do echo "== $f"; grep '^kind:' evidence/K1-render-$f.yaml | sort | uniq -c; done
grep -n 'name: app-config\|name: app-secret' evidence/K1-render-dev.yaml
```

📸 **S01-kustomize-render** — object counts (base 13, dev 15, prod 15) and the
hashed names `app-config-xxxxxxxxxx` / `app-secret-xxxxxxxxxx`.

📝 The base has no Secret and no Namespace: each overlay adds its own.

### K2. What differs between dev and prod

```bash
diff evidence/K1-render-dev.yaml evidence/K1-render-prod.yaml | grep -E '^[<>]' \
  | grep -vE 'app-(config|secret)-|namespace: dso202|environment: (dev|prod)|name: dso202|PASSWORD'
```

📸 **S02-dev-vs-prod-diff** — quota, CORS, replicas 1→2 (twice), backend
resources, `storage: 2Gi`, host. (Namespace, environment label and password
lines are filtered out because they differ on every object.)

📝 Map each difference to its mechanism: `namespace:`, `labels:`, `replicas:`,
strategic merge (resources, quota), JSON 6902 (storage, host),
`configMapGenerator behavior: merge` (CORS), `secretGenerator`.

### K3. Labels never touch selectors

```bash
grep -A3 'matchLabels:' evidence/K1-render-prod.yaml
grep -B2 -A8 '  template:' evidence/K1-render-prod.yaml | grep -A6 'labels:' | head -8
```

📸 **S03-selectors-vs-labels** — selectors only `app`/`tier`; Pod template
labels also carry `app.kubernetes.io/environment`, `part-of`, `managed-by`.

📝 Why `includeSelectors: false`: selectors are immutable (you hit this in A2).

### K4. Deploy dev — diff first, then apply

```bash
NS=dso202-a3-kust-dev
kubectl apply -f kustomize/overlays/dev/namespace.yaml
kubectl diff -k kustomize/overlays/dev | head -40
```

📸 **S04-kubectl-diff** — the server-side preview (everything shown as new).

📝 The namespace is applied first because `kubectl diff` does a server dry
run, which fails for objects in a namespace that does not exist yet.

```bash
kubectl apply -k kustomize/overlays/dev
kubectl wait -n $NS --for=condition=ready pod -l app=database --timeout=600s   # ⏱ 1–3 min
kubectl wait -n $NS --for=condition=ready pod -l app=backend  --timeout=300s
kubectl get all,pvc,ingress,cm,secret -n $NS
kubectl get endpoints db-svc -n $NS
```

📸 **S05-kust-dev-running** — all Pods 1/1, PVC `data-db-0` Bound, Ingress
host `kust-dev.tasks.local`, and `db-svc` **with an endpoint** (the A2 bug is fixed).

### K5. Test through the Ingress

```bash
curl -s http://kust-dev.tasks.local:30080/api/status; echo
curl -s http://kust-dev.tasks.local:30080/api/tasks; echo
curl -s -o /dev/null -w 'frontend: HTTP %{http_code}\n' http://kust-dev.tasks.local:30080/
```

📸 **S06-kust-dev-curl** — `{"status":"ok","db":"connected"}` and the 3 seed tasks.

Open **http://kust-dev.tasks.local:30080** in the browser. Add a task, change
its status, delete one.

📸 **S07-kust-dev-browser** — the UI with your task (address bar visible).

📝 No custom nginx.conf or entrypoint any more: `BACKEND_URL=.` makes the
browser call `./api/tasks`, which the Ingress routes to the backend.

### K6. StatefulSet persistence (Pod deletion, then StatefulSet deletion)

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Persistence test","description":"must survive db-0 deletion"}' \
  http://kust-dev.tasks.local:30080/api/tasks; echo
kubectl get pod db-0 -n $NS -o wide
kubectl delete pod db-0 -n $NS
kubectl wait -n $NS --for=condition=ready pod/db-0 --timeout=600s              # ⏱
kubectl get pod db-0 -n $NS -o wide
sleep 10; curl -s http://kust-dev.tasks.local:30080/api/tasks | grep -o '"title":"Persistence test"'
```

📸 **S08-pod-deletion** — same name `db-0`, same PVC, task still there.

Now delete the **StatefulSet itself** (not the namespace):

```bash
kubectl delete statefulset db -n $NS
kubectl get pvc -n $NS                    # still Bound: persistentVolumeClaimRetentionPolicy Retain
kubectl apply -k kustomize/overlays/dev   # recreates only the StatefulSet
kubectl wait -n $NS --for=condition=ready pod/db-0 --timeout=600s              # ⏱
sleep 10; curl -s http://kust-dev.tasks.local:30080/api/tasks | grep -o '"title":"Persistence test"'
```

📸 **S09-statefulset-retain** — PVC survives the StatefulSet deletion; the new
`db-0` re-attaches it and the task is still there.

### K7. Config change → new hash → rolling update

Done on a **copy** so the repository stays clean:

```bash
rm -rf /tmp/kdemo && cp -r kustomize /tmp/kdemo
sed -i 's|^CORS_ORIGIN=.*|CORS_ORIGIN=http://kust-dev.tasks.local:30080|' /tmp/kdemo/base/config.env
kubectl get cm -n $NS
kubectl get pods -n $NS
kubectl diff -k /tmp/kdemo/overlays/dev | grep -E '^[+-].*app-config' | head
kubectl apply -k /tmp/kdemo/overlays/dev
kubectl rollout status deployment/backend  -n $NS --timeout=300s
kubectl rollout status deployment/frontend -n $NS --timeout=300s
kubectl get cm -n $NS
kubectl get pods -n $NS
```

📸 **S10-hash-rollout** — two `app-config-*` ConfigMaps, the diff swapping the
reference, and new Pods (small AGE). `db-0` restarts too (it also uses app-config).

📝 Chain: content changes → hash changes → reference changes → Pod template
changes → rollout. 📝 Observation: Kustomize leaves the **old** ConfigMap
behind (no pruning) — it is harmless but must be cleaned manually.

Restore the committed configuration:

```bash
kubectl apply -k kustomize/overlays/dev
kubectl rollout status deployment/backend -n $NS --timeout=300s
kubectl wait -n $NS --for=condition=ready pod/db-0 --timeout=600s
```

### K8. Deploy prod

```bash
NSP=dso202-a3-kust-prod
kubectl apply -f kustomize/overlays/prod/namespace.yaml
kubectl apply -k kustomize/overlays/prod
kubectl wait -n $NSP --for=condition=ready pod -l app=database --timeout=600s  # ⏱
kubectl wait -n $NSP --for=condition=ready pod -l app=backend  --timeout=300s
kubectl get pods,pvc,ingress -n $NSP -o wide
kubectl describe resourcequota task-tracker-quota -n $NSP | tail -12
curl -s http://kust-prod.tasks.local:30080/api/status; echo
```

📸 **S11-kust-prod-running** — 2 backend + 2 frontend Pods spread over the
workers, PVC **2Gi**, raised quota with its usage, prod host answering.

📸 **S12-two-environments** — both environments side by side, isolated data:
```bash
kubectl get pods -A -l app.kubernetes.io/part-of=task-tracker
curl -s http://kust-dev.tasks.local:30080/api/tasks  | grep -c '"id"'
curl -s http://kust-prod.tasks.local:30080/api/tasks | grep -c '"id"'
```
(dev has your extra tasks, prod has only the 3 seed tasks.)

### K9. Delete with Kustomize

```bash
kubectl delete -k kustomize/overlays/dev
kubectl delete -k kustomize/overlays/prod
kubectl get ns | grep a3-kust || echo "kustomize namespaces gone"
kubectl get pv
```

📸 **S13-kustomize-delete** — everything removed, including the PVCs.

📝 Important finding: `delete -k` also deletes the **Namespace** (it is a
resource of the overlay), and deleting a namespace deletes its PVCs
regardless of the StatefulSet's `Retain` policy. `Retain` only protects the
PVC from StatefulSet deletion/scale-down (shown in K6).

---

## Phase 2 — Helm

All Helm commands run from `assignment-3/helm`.

```bash
cd ~/Desktop/SEM_7/DSO202/SS26_DSO202/assignment/assignment-3/helm
```

### H1. Chart structure and lint

```bash
find task-tracker -type f | sort
helm show chart ./task-tracker
for e in dev prod; do helm lint ./task-tracker -f environments/$e.yaml -f environments/secrets-$e.yaml; done
```

📸 **S14-chart-structure-lint** — the file tree, Chart.yaml (version vs
appVersion), and `0 chart(s) failed` for both environments.

### H2. Render locally

```bash
helm template task-tracker-dev ./task-tracker -n dso202-a3-helm-dev \
  -f environments/dev.yaml -f environments/secrets-dev.yaml > ../evidence/H2-render-dev.yaml
grep '^kind:' ../evidence/H2-render-dev.yaml | sort | uniq -c
helm template task-tracker-dev ./task-tracker -n dso202-a3-helm-dev \
  -f environments/dev.yaml -f environments/secrets-dev.yaml -s templates/backend-deployment.yaml
```

📸 **S15-helm-template** — names derived from the release
(`task-tracker-dev-backend`), stable selector labels vs full label set,
`checksum/config` + `checksum/secret`, image tag taken from `appVersion`.

### H3. Validation layers — make it fail on purpose

```bash
T="helm template task-tracker-dev ./task-tracker -n dso202-a3-helm-dev"
echo "--- F1 no environment";  $T 2>&1 | head -1
echo "--- F2 no credentials";  $T -f environments/dev.yaml 2>&1 | head -1
printf 'images:\n  backend:\n    tag: 1.0\n' > /tmp/tag-float.yaml
echo "--- F3 unquoted tag";    $T -f environments/dev.yaml -f environments/secrets-dev.yaml -f /tmp/tag-float.yaml 2>&1 | head -3
echo "--- F4 several bad values"; $T -f environments/dev.yaml -f environments/secrets-dev.yaml \
  --set backend.replicaCount=0 --set images.pullPolicy=Sometimes --set environment=test --set database.storage.size=2GB 2>&1 | head -6
echo "--- F5 lint alone";      helm lint ./task-tracker | tail -1; echo "exit code $?"
```

📸 **S16-validation-failures** — `required` messages (F1, F2), schema errors
(F3: `got number, want string` — YAML read 1.0 as a number; F4: four errors
at once), and `helm lint` passing with exit code 0 even with no values.

Now a misspelled Kubernetes field, on a **copy** of the chart:

```bash
rm -rf /tmp/tt-broken && cp -r task-tracker /tmp/tt-broken
sed -i 's/^  replicas: {{ .Values.backend.replicaCount }}/  replica: {{ .Values.backend.replicaCount }}/' /tmp/tt-broken/templates/backend-deployment.yaml
helm lint /tmp/tt-broken -f environments/dev.yaml -f environments/secrets-dev.yaml | tail -1
helm template x /tmp/tt-broken -f environments/dev.yaml -f environments/secrets-dev.yaml > /dev/null && echo "helm template: OK (did not catch it)"
helm template x /tmp/tt-broken -f environments/dev.yaml -f environments/secrets-dev.yaml --skip-tests \
  | kubectl apply --dry-run=server -n default -f - 2>&1 | tail -3
```

📸 **S17-misspelled-field** — lint and template pass; only the server-side
dry run rejects `unknown field "spec.replica"`.

📝 Table for the report: which check catches which error (lint / template /
schema / server dry run).

### H4. Install dev

```bash
helm upgrade --install task-tracker-dev ./task-tracker \
  -n dso202-a3-helm-dev --create-namespace \
  -f environments/dev.yaml -f environments/secrets-dev.yaml \
  --wait --timeout 15m                                                      # ⏱ 2–5 min
```

📸 **S18-helm-install-dev** — `STATUS: deployed`, `REVISION: 1`, and the NOTES.

```bash
helm list -A
kubectl get all,pvc,ingress -n dso202-a3-helm-dev
curl -s http://helm-dev.tasks.local:30080/api/status; echo
```

📸 **S19-helm-dev-running** — release listed, objects named
`task-tracker-dev-*`, PVC Bound, API ok. Open
**http://helm-dev.tasks.local:30080** and add a task named **"Helm data"**.

📸 **S20-helm-dev-browser**

### H5. Chart tests

```bash
helm test task-tracker-dev -n dso202-a3-helm-dev --logs
```

📸 **S21-helm-test** — `Phase: Succeeded` and `ALL TESTS PASSED`
(backend Service, frontend Service, and the full Ingress path).

### H6. The release record — and the secret problem

```bash
kubectl get secrets -n dso202-a3-helm-dev --show-labels | grep -E 'NAME|owner=helm'
helm get values task-tracker-dev -n dso202-a3-helm-dev
kubectl get secret sh.helm.release.v1.task-tracker-dev.v1 -n dso202-a3-helm-dev \
  -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('name:',r['name'],' version:',r['version'],' status:',r['info']['status'],' apply_method:',r.get('apply_method'))"
```

📸 **S22-release-record** — the `sh.helm.release.v1...` Secret, the
**plain-text password** in `helm get values`, and `apply_method: ssa`.

📝 Helm does not keep secrets secret: anyone who can read Secrets in the
namespace can recover the password.

### H7. Install prod

```bash
helm upgrade --install task-tracker-prod ./task-tracker \
  -n dso202-a3-helm-prod --create-namespace \
  -f environments/prod.yaml -f environments/secrets-prod.yaml \
  --wait --timeout 15m                                                      # ⏱
kubectl get pods,pvc -n dso202-a3-helm-prod -o wide
helm list -A
curl -s http://helm-prod.tasks.local:30080/api/status; echo
```

📸 **S23-helm-prod** — 2+2 replicas, PVC 2Gi, both releases listed.

### H8. Upgrade dev (revision 2)

```bash
kubectl get deploy task-tracker-dev-backend -n dso202-a3-helm-dev \
  -o jsonpath='{.spec.template.metadata.annotations.checksum/config}{"\n"}'
helm upgrade task-tracker-dev ./task-tracker -n dso202-a3-helm-dev \
  -f environments/dev.yaml -f environments/secrets-dev.yaml \
  --set backend.replicaCount=2 \
  --set backend.corsOrigin=http://helm-dev.tasks.local:30080 \
  --wait --timeout 15m                                                      # ⏱ db restarts too
kubectl get deploy task-tracker-dev-backend -n dso202-a3-helm-dev \
  -o jsonpath='{.spec.template.metadata.annotations.checksum/config}{"\n"}'
kubectl get pods -n dso202-a3-helm-dev
```

📸 **S24-helm-upgrade** — `REVISION: 2`, a **different** checksum, 2 backend
Pods, all Pods freshly restarted (config changed → checksum → rollout).

### H9. The `--set`-only upgrade pitfall

```bash
helm upgrade task-tracker-dev ./task-tracker -n dso202-a3-helm-dev --set backend.replicaCount=3
helm history task-tracker-dev -n dso202-a3-helm-dev
```

📸 **S25-set-pitfall** — the upgrade is **refused** with
`environment must be set`.

📝 With any value flag, `helm upgrade` starts again from the chart defaults
and drops the earlier values. In the course demo this silently halved the
replicas; this chart's `required` checks turn the silent failure into an
error. Note whether `helm history` recorded the attempt.

### H10. History and rollback

```bash
helm rollback task-tracker-dev 1 -n dso202-a3-helm-dev --wait --timeout 15m  # ⏱
helm history task-tracker-dev -n dso202-a3-helm-dev
helm get values task-tracker-dev -n dso202-a3-helm-dev | grep -A2 backend || echo "no backend overrides (revision 1 values)"
kubectl get pods -n dso202-a3-helm-dev
curl -s http://helm-dev.tasks.local:30080/api/tasks | grep -o '"title":"Helm data"'
```

📸 **S26-rollback** — history 1 superseded, 2 superseded, 3 `Rollback to 1`;
1 backend Pod again; **"Helm data" still present**.

📝 Rollback re-applies manifests, it does not restore data — and the data
survived because it lives in the PVC.

### H11. Uninstall — the PVC stays behind

```bash
helm uninstall task-tracker-dev -n dso202-a3-helm-dev
kubectl get all,pvc -n dso202-a3-helm-dev
kubectl get ns dso202-a3-helm-dev
```

📸 **S27-uninstall-pvc** — workloads gone, but `data-task-tracker-dev-db-0`
is still Bound and the namespace still exists.

Reinstall with the **same** credentials: the old volume is re-attached.

```bash
helm upgrade --install task-tracker-dev ./task-tracker -n dso202-a3-helm-dev \
  -f environments/dev.yaml -f environments/secrets-dev.yaml --wait --timeout 15m   # ⏱
curl -s http://helm-dev.tasks.local:30080/api/tasks | grep -o '"title":"Helm data"'
helm history task-tracker-dev -n dso202-a3-helm-dev
```

📸 **S28-reinstall-data** — "Helm data" survived uninstall + reinstall;
history starts again at revision 1.

📝 Trap: Postgres only reads POSTGRES_PASSWORD when the volume is empty. A
reinstall with a **different** password would fail to log in. Delete the PVC
when a clean start is wanted.

### H12. Package

```bash
helm package ./task-tracker          # writes task-tracker-0.1.0.tgz here (gitignored)
ls -l task-tracker-*.tgz
tar tzf task-tracker-0.1.0.tgz
```

📸 **S29-helm-package** — `task-tracker-0.1.0.tgz` (contains no secrets: the
environment files are outside the chart).

---

## Phase 3 — Clean up and commit

```bash
helm uninstall task-tracker-dev  -n dso202-a3-helm-dev
helm uninstall task-tracker-prod -n dso202-a3-helm-prod
kubectl delete ns dso202-a3-helm-dev dso202-a3-helm-prod
cd ~/Desktop/SEM_7/DSO202/SS26_DSO202
git add assignment/assignment-3
git diff --cached --name-only | grep -E 'db-secret\.env$|secrets-(dev|prod)\.yaml$|\.tgz$' \
  && echo "!! STOP: secret or package staged" || echo "safe to commit"
git commit -m "a3: kustomize base/overlays, helm chart, evidence"
```

📸 **S30-git-safe** — `safe to commit`.

The report (README.md) is written last, using the screenshots and 📝 notes.

---

## Screenshot index

| # | Shows | # | Shows |
|---|---|---|---|
| S00 | environment + tool versions | S16 | validation failures F1–F5 |
| S01 | Kustomize render, hashed names | S17 | misspelled field: only server dry run |
| S02 | dev vs prod rendered diff | S18 | helm install dev |
| S03 | selectors vs labels | S19 | helm dev running |
| S04 | kubectl diff -k | S20 | helm dev browser |
| S05 | kust dev running, db-svc endpoint | S21 | helm test |
| S06 | curl through Ingress | S22 | release record + plain password |
| S07 | browser CRUD | S23 | helm prod |
| S08 | db-0 pod deletion persistence | S24 | upgrade rev 2, checksum rollout |
| S09 | StatefulSet deletion, PVC Retain | S25 | --set pitfall refused |
| S10 | hash change rollout | S26 | history + rollback, data kept |
| S11 | kust prod running | S27 | uninstall keeps PVC |
| S12 | dev/prod isolation | S28 | reinstall re-attaches data |
| S13 | delete -k | S29 | helm package |
| S14 | chart tree + lint | S30 | git safe to commit |
| S15 | helm template output | | |
