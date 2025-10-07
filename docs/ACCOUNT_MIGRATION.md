# Account Migration Runbook (AWS → AWS)

This guide walks you through migrating the Taskflow dev environment to a new AWS account safely, predictably, and with minimal downtime.

## Scope & Assumptions
- Source: current AWS account hosting EKS, ECR, VPC, IAM via Terraform in this repo.
- Target: a different AWS account in the same region (us-east-2). If changing region, update references accordingly.
- Artifacts: ECR images for backend/frontend, Kubernetes manifests, Terraform state backend (S3/DynamoDB).
- DNS: If the app will be reachable via a custom domain, plan Route53/ACM in the target account.

## High-level Strategy
Choose one:
- Blue/Green (recommended): Stand up the full stack in the target account, validate, then cut DNS/traffic over.
- In-place state move (not recommended for prod): Move Terraform state and recreate resources (higher blast radius).

## Prerequisites
- Access to both AWS accounts (IAM user/role or SSO), with profiles configured in your CLI (e.g., `aws sso login`).
- Quotas checked (EKS, ALB, EC2, ECR, VPC subnets/ENIs, KMS if used).
- Terraform >= 1.6, kubectl, docker/buildx.

## 1) Bootstrap the Target Account
Create Terraform remote state backend in the target account.
- Option A (automated): use `bootstrap/` module in the target account profile.
  ```bash
  cd bootstrap
  AWS_PROFILE=<target> terraform init && terraform apply -auto-approve
  ```
  Outputs: S3 bucket name and DynamoDB table.
- Option B (existing shared backend): reuse a pre-provisioned S3/DynamoDB.

Record:
- S3 bucket: `<new-tfstate-bucket>`
- DynamoDB table: `<new-tf-locks-table>`

## 2) Prepare Terraform for Target
In `envs/dev/backend.tf`, point to the target account backend:
```hcl
terraform {
  backend "s3" {
    bucket         = "<new-tfstate-bucket>"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "<new-tf-locks-table>"
    encrypt        = true
  }
}
```
In `envs/dev/providers.tf`, set the target region; use `AWS_PROFILE=<target>` when running Terraform.

## 3) Account-specific Values
- IAM ARNs: Any hard-coded account IDs (e.g., `arn:aws:iam::<account_id>`) in `envs/dev/main.tf` must be updated to the target account ID.
- Access entries (EKS `aws-auth`/access entries): update principal ARNs.
- Tags/names: keep consistent naming or add `-new` suffix for parallel runs.

## 4) ECR Images (Cross-Account)
You need images present in the target account’s ECR.
- Option A: Retag & push from your workstation (fastest):
  ```bash
  # login to target ECR
  aws ecr get-login-password --profile <target> --region us-east-2 \
    | docker login --username AWS --password-stdin <targetAccount>.dkr.ecr.us-east-2.amazonaws.com

  # pull from source (if private, login to source first), retag and push
  docker pull <sourceAccount>.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:<tag>
  docker tag  <sourceAccount>.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:<tag> \
              <targetAccount>.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:<tag>
  docker push <targetAccount>.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:<tag>

  # repeat for frontend
  ```
- Option B: Set up ECR cross-account replication (longer setup, ongoing convenience).

Update manifests/images if repository URLs change.

## 5) Apply Infra in Target (Blue/Green)
Create a fresh stack in the target account.
```bash
cd envs/dev
AWS_PROFILE=<target> terraform init
AWS_PROFILE=<target> terraform plan -out=tfplan
AWS_PROFILE=<target> terraform apply tfplan
```
This will create: VPC, EKS, node groups (on-demand/spot), security groups, ECR, etc.

## 6) Cluster Bootstrap in Target
- Configure kubeconfig:
  ```bash
  AWS_PROFILE=<target> aws eks update-kubeconfig --region us-east-2 --name taskflow-dev-eks
  ```
- Install NGINX Ingress Controller:
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/aws/deploy.yaml
  ```
- Apply RBAC and app manifests:
  ```bash
  kubectl apply -f k8s-manifests/rbac-admin.yaml || true
  kubectl apply -f k8s-manifests/postgres-deployment.yaml
  kubectl apply -f k8s-manifests/backend-deployment.yaml
  kubectl apply -f k8s-manifests/frontend-deployment.yaml
  kubectl apply -f k8s-manifests/ingress.yaml
  ```
- Create secrets required by the app (passwords/JWT):
  ```bash
  kubectl create secret generic postgres-secret --from-literal=password='<password>'
  ```
- Set backend CORS allowed origins to the new Ingress hostname (see step 8):
  ```bash
  kubectl set env deploy/taskflow-backend CORS_ALLOWED_ORIGINS=http://<new-ingress-host>,http://localhost:3000
  ```

## 7) Images in Target Cluster
If your manifests reference `<sourceAccount>` ECR, update them to the target ECR repo URLs or use `kubectl set image`:
```bash
kubectl set image deploy/taskflow-backend backend=<targetAccount>.dkr.ecr.us-east-2.amazonaws.com/taskflow-backend:<tag>
kubectl set image deploy/taskflow-frontend frontend=<targetAccount>.dkr.ecr.us-east-2.amazonaws.com/taskflow-frontend:<tag>
```

## 8) Validate in Target
- Get Ingress hostname:
  ```bash
  kubectl get ingress taskflow-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  ```
- Smoke tests:
  ```bash
  curl -I http://<ingress>/
  curl -i -X OPTIONS http://<ingress>/api/tasks -H "Origin: http://<ingress>" -H "Access-Control-Request-Method: GET"
  ```
- App flows (login/register, tasks CRUD) through the browser.

## 9) DNS & TLS (Optional)
- If using a custom domain, create Route53 hosted zone or use existing.
- Request ACM certificate in target account (us-east-2) and validate.
- Point domain (A/ALIAS) to the Ingress ALB hostname.
- Optionally use Ingress TLS with ACM via AWS Load Balancer Controller (instead of NGINX) for deeper L7 features.

## 10) Cutover Plan (Blue/Green)
- Announce maintenance window (if needed).
- Freeze changes in source.
- Final image sync to target ECR.
- Flip DNS (ALIAS to new Ingress ALB).
- Monitor logs/metrics and functional tests.
- If issues, roll back DNS to source.

## 11) Post-cutover Cleanup
- Decommission source account resources once stable: EKS cluster, ALBs, ECR repos, VPC.
- Archive/retain Terraform state and S3 objects per policy.

## 12) Rollback Strategy
- Keep source stack intact until stabilization.
- Document the last known-good images/tags.
- DNS rollback is the primary quick-restore.

## 13) Tips & Gotchas
- IRSA/OIDC: EKS OIDC provider differs by account; re-provision via module (already handled by Terraform).
- Quotas: ALB/NLB limits, ENIs per subnet/instance, LaunchTemplate caps.
- CORS: Update backend env `CORS_ALLOWED_ORIGINS` to the new hostname before client testing.
- Next.js base URL: Build frontend with `NEXT_PUBLIC_API_BASE_URL=/` so it calls same-origin `/api`.
- Costs: keep on-demand minimal; enable Spot after validation; single ALB via Ingress.

## 14) Checklist
- [ ] Target state backend created (S3/DynamoDB)
- [ ] Terraform account IDs updated
- [ ] ECR images available in target
- [ ] EKS/Ingress installed and healthy
- [ ] Secrets created (DB/JWT)
- [ ] Manifests applied; HPAs functioning
- [ ] CORS configured for new host
- [ ] DNS cutover executed
- [ ] Monitoring/validation complete
- [ ] Source cleanup scheduled

---
Questions or gaps? Update this runbook after each migration to keep it accurate.
