# Taskflow IaC - Technical Details

This document captures the DevOps-facing details for the Taskflow environment (dev) hosted on AWS EKS.

## Architecture Overview
- VPC: Terraform-managed, public subnets only for dev, NAT disabled
- EKS: terraform-aws-modules/eks v20, IRSA enabled, public endpoint
- Node groups:
  - On-demand baseline: t3.small (min 1, desired 1–2)
  - Spot (burst): mixed types, desired 0 by default (dev)
- ECR: backend/frontend image repos
- Ingress: NGINX Ingress Controller (single ALB)
- Services: ClusterIP for frontend/backend; Ingress routes `/` → frontend and `/api` → backend
- Postgres: Dev-only Deployment + ClusterIP Service

## Repos and Images
- Backend code: `../task-manager-backend` (Spring Boot)
- Frontend code: `../task-manager-frontend` (Next.js 15)
- Images in ECR:
  - `226680475141.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:<tag>`
  - `226680475141.dkr.ecr.us-east-2.amazonaws.com/taskflow-frontend:<tag>`

## Terraform Layout
- `envs/dev`
  - `main.tf`: VPC, ECR, EKS
  - `providers.tf`, `backend.tf`
- Bootstrap (state backend): `bootstrap/`

Apply dev infra:
```bash
cd envs/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Outputs:
- `cluster_name`, `vpc_id`, ECR repo URLs

## Kubernetes Manifests
- `k8s-manifests/`
  - `frontend-deployment.yaml`, `backend-deployment.yaml`
  - `postgres-deployment.yaml`
  - `ingress.yaml`

Ingress routing (nginx):
- `/api` → `taskflow-backend-service:8080`
- `/` → `taskflow-frontend-service:3000`

## Ingress Controller
Installed via static manifest:
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/aws/deploy.yaml
```
Ingress URL:
```bash
kubectl get ingress taskflow-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Autoscaling and Resources
- HPAs for frontend/backend target 60% CPU
- Requests/limits defined to enable bin-packing
- Spot preference via `nodeAffinity` (preferred, not required)

## Cost Controls (dev)
- On-demand baseline low (t3.small)
- Spot burst set to desired 0 normally
- Single ALB via Ingress
- Public subnets; no NAT

## CORS and Security
- Backend CORS allowed origins via env `CORS_ALLOWED_ORIGINS`
  - Set to Ingress hostname and localhost for dev
- Security rules:
  - `/api/auth/**` permit-all
  - all other `/api/**` require JWT (Authorization: Bearer <token>)

## Frontend Base URL
- Next.js uses `NEXT_PUBLIC_API_BASE_URL` at build time
  - We build with `/` so browser calls `/api/...` (same-origin)
  - For local/minikube, set `NEXT_PUBLIC_API_BASE_URL=/api`

## Build & Push Images (amd64)
```bash
# login
aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 226680475141.dkr.ecr.us-east-2.amazonaws.com

# backend
docker buildx create --use || true
docker buildx build --platform linux/amd64 -t 226680475141.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:vX.Y.Z ../task-manager-backend --push

# frontend (base '/')
docker buildx build --platform linux/amd64 --build-arg NEXT_PUBLIC_API_BASE_URL=/ -t 226680475141.dkr.ecr.us-east-2.amazonaws.com/taskflow-frontend:vX.Y.Z ../task-manager-frontend --push
```

Roll out:
```bash
kubectl set image deploy/taskflow-backend backend=.../taskflow-backend:vX.Y.Z
kubectl set image deploy/taskflow-frontend frontend=.../taskflow-frontend:vX.Y.Z
kubectl rollout status deploy/taskflow-backend
kubectl rollout status deploy/taskflow-frontend
```

## Troubleshooting
- 503 from Ingress
  - Check endpoints: `kubectl get endpoints taskflow-*-service`
  - Pods ready? `kubectl get pods`, inspect logs
- CORS blocked in browser
  - Ensure `CORS_ALLOWED_ORIGINS` includes the Ingress hostname
  - Preflight check: `curl -i -X OPTIONS http://<ingress>/api/... -H 'Origin: http://<ingress>' -H 'Access-Control-Request-Method: GET'`
- Frontend assets not loading
  - Use prefix Ingress (no rewrite); ensure `/_next/...` paths 200/308
- Backend 403
  - Requires JWT except `/api/auth/**`. Log in first

## Future Enhancements
- Metrics Server + HPAs smoothing
- Cluster Autoscaler or Karpenter with consolidation
- Private subnets + VPC endpoints (reduce egress)
- Switch Postgres to managed RDS for prod
