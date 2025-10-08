## Taskflow Infrastructure: Plain-English Guide (From Zero to Running)

This guide explains, in simple terms, how we bring the Taskflow app (frontend + backend + database) to life on AWS. No DevOps background required.

### What we’re setting up
- **A place to run the app**: a managed Kubernetes cluster on AWS.
- **Networking**: lets the cluster talk to the internet and gives you a public web address.
- **Two app images**: one for the backend, one for the frontend, stored in AWS.
- **A public URL**: so anyone can open the app in a browser.

### Key pieces in this repo
- `bootstrap/`: one-time setup so Terraform (our automation tool) has a safe place to store its records.
- `envs/dev/`: the dev environment definition (network, cluster, image repositories).
- `k8s-manifests/`: the app pieces the cluster runs (frontend, backend, database, and the public URL routing).

---

## 1) One-time bootstrap (safe storage for automation)
Purpose: create a private, versioned, encrypted S3 bucket and a tiny database (DynamoDB table) to keep Terraform runs safe and in sync.

What it does:
- Creates a secure S3 bucket where Terraform saves “what exists right now.”
- Creates a DynamoDB table used as a lock, so two people don’t make conflicting changes at the same time.

Run it (from the repo root):
```bash
cd bootstrap
terraform init
terraform apply -auto-approve
```

You run this once per AWS account. After that, other environments (like `envs/dev`) can use the storage it created.

---

## 2) Build the dev environment
Purpose: set up the network, the Kubernetes cluster, and two image repositories.

What it does:
- Sets up a public network with DNS so we can get a public web address for the app.
- Creates two image repositories (backend and frontend) where the cluster pulls app images from.
- Creates the Kubernetes cluster that will run your app.

Run it:
```bash
cd envs/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Notes:
- This uses the bucket and lock created in the bootstrap step.
- When it finishes, Terraform prints helpful outputs like the cluster name and image repository URLs.

---

## 3) Connect to the cluster
Purpose: so you can deploy the app and check it.

Run:
```bash
aws eks update-kubeconfig --region us-east-2 --name taskflow-dev-eks
kubectl get nodes
```

You should see one or more nodes (machines) listed.

---

## 4) Install the public entry point (Ingress Controller)
Purpose: give the app a single public web address.

Run:
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/aws/deploy.yaml
```

This adds a standard “front door” to the cluster. It will later give you a public hostname.

---

## 5) Deploy the app
Purpose: run the frontend, backend, database, and the routing rules.

Run from repo root:
```bash
kubectl apply -f k8s-manifests/
```

What this includes:
- Frontend Deployment + Service (serves the website)
- Backend Deployment + Service (serves `/api`)
- Postgres (dev-only) + a Secret for its password
- Ingress (the routing rules):
  - `/` → frontend
  - `/api` → backend

---

## 6) Get the public URL
Purpose: open the app in a browser.

Run:
```bash
kubectl get ingress taskflow-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open the printed URL in your browser:
- Frontend is served at `/`
- Backend API is at `/api`

---

## 7) Update the app when code changes (optional)
Purpose: roll out new versions of the frontend/backend images.

High level:
1) Build and push new images to the two image repositories (backend and frontend).
2) Tell the cluster to use the new image tags.

Commands you might see used:
```bash
# Example of telling the cluster to use a new image tag
kubectl set image deploy/taskflow-backend backend=<ECR_URL>/taskflow-backend:vX.Y.Z
kubectl set image deploy/taskflow-frontend frontend=<ECR_URL>/taskflow-frontend:vX.Y.Z
kubectl rollout status deploy/taskflow-backend
kubectl rollout status deploy/taskflow-frontend
```

---

## 8) Common checks
```bash
kubectl get pods
kubectl logs deploy/taskflow-frontend
kubectl logs deploy/taskflow-backend
kubectl get ingress taskflow-ingress
```

If the browser can’t reach the app, wait a minute or two for the public URL to appear and the app to finish starting.

---

## 9) What each folder means (recap)
- `bootstrap/`: one-time storage and lock for safe changes.
- `envs/dev/`: creates the network, image repos, and the cluster.
- `k8s-manifests/`: tells the cluster what to run and how to route `/` and `/api` to your two services.

With these steps, a non-DevOps person can take the app from nothing to a working public URL.

---

## 10) Destroying everything (when you’re done)
Goal: cleanly remove the app and the infrastructure.

Order matters: app first, then infrastructure. Only remove the bootstrap if you truly want to wipe everything.

1) Remove the app (including the public URL):
```bash
kubectl delete -f k8s-manifests/
# Optional: uninstall the ingress controller (removes the public entry point)
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/aws/deploy.yaml
```

2) Destroy the dev infrastructure:
```bash
cd envs/dev
terraform destroy -auto-approve
```

If you see an error saying the cluster has node groups attached, remove them first and then rerun the destroy:
```bash
aws eks list-nodegroups --cluster-name taskflow-dev-eks --region us-east-2
```
Example output:
```json
{
    "nodegroups": [
        "default-20251006210852453600000017"
    ]
}
```
Delete and wait for each node group shown (use your exact names):
```bash
aws eks delete-nodegroup --cluster-name taskflow-dev-eks --nodegroup-name default-20251006210852453600000017 --region us-east-2
aws eks wait nodegroup-deleted --cluster-name taskflow-dev-eks --nodegroup-name default-20251006210852453600000017 --region us-east-2
```

If you see errors about image repositories not being empty force-delete the repos:

```bash
aws ecr delete-repository --repository-name taskflow-frontend --region us-east-2 --force
aws ecr delete-repository --repository-name taskflow-backend --region us-east-2 --force
```

3) Optional: remove the bootstrap (not typical — this wipes Terraform’s saved records):
```bash
# First make sure step 2 finished successfully.
cd ../..
cd bootstrap
# If Terraform asks you to empty the S3 bucket first (it’s versioned),
# use the AWS Console to empty the bucket, then run:
terraform destroy -auto-approve
```

Tip: Keep the bootstrap unless you’re retiring the account — it stores history/locks for safe changes.


