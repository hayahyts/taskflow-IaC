# Taskflow - Infrastructure & How to Run (Simple)

This repo contains the infrastructure and Kubernetes manifests to run Taskflow (frontend + backend + Postgres) on AWS EKS.

Start here if you just want to run and access the app. No DevOps background needed. For DevOps/infra details, see [Technical Details](docs/TECHNICAL_DETAILS.md).

## What we use
- AWS EKS (Kubernetes)
- Terraform (EKS, VPC, ECR, IAM)
- NGINX Ingress Controller (single URL)
- Amazon ECR (container images)
- Postgres (K8s Deployment for dev)

## One-time setup (already done in dev env)
- EKS cluster: taskflow-dev-eks
- Ingress URL: created automatically. To print it:
  
  ```bash
  kubectl get ingress taskflow-ingress
  ```

## How to access the app
1) Get the ingress URL:
   ```bash
   kubectl get ingress taskflow-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
   ```
2) Open the URL in your browser.
3) Frontend is served at `/`, backend API at `/api`.

## Common developer tasks
- Restart deployments after code/image updates:
  ```bash
  kubectl rollout restart deploy/taskflow-frontend
  kubectl rollout restart deploy/taskflow-backend
  ```
- Check app health:
  ```bash
  kubectl get pods
  kubectl logs deploy/taskflow-frontend
  kubectl logs deploy/taskflow-backend
  ```

## Building new images (optional)
If you changed code in sibling repos `task-manager-frontend` or `task-manager-backend`, build and push images to ECR, then restart deployments. Ask a DevOps engineer or see [Technical Details](docs/TECHNICAL_DETAILS.md) for the exact commands.

## Need more details?
See [docs/TECHNICAL_DETAILS.md](docs/TECHNICAL_DETAILS.md) for Terraform, cluster design, cost controls, autoscaling, networking, and troubleshooting.
