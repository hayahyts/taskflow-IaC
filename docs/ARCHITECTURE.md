## Taskflow Architecture (AWS + EKS)

This diagram shows how Terraform-provisioned AWS resources, EKS, and your Kubernetes workloads fit together.

```mermaid
flowchart LR
  subgraph AWS[Amazon Web Services - Account 226680475141]
    subgraph VPC[VPC + Subnets + Security Groups]
      NLB[ELBv2 NLB<br/>internet-facing]
      subgraph EKS[EKS: taskflow-dev-eks]
        CP[(EKS Control Plane)]
        subgraph NodeGroup[EC2 Node Group - 3 nodes]
          N1[(Node 1)]
          N2[(Node 2)]
          N3[(Node 3)]
        end
        subgraph K8s[Cluster Resources]
          Ingress[Ingress Controller]
          SVCF[Service: frontend]
          SVCB[Service: backend]
          subgraph Apps[Applications]
            FE[(Deployment: taskflow-frontend<br/>Pods)]
            BE[(Deployment: taskflow-backend<br/>Pods)]
            PG[(Deployment: postgres<br/>Pod)]
          end
        end
      end
    end
    ECR1[(ECR: taskflow-frontend)]
    ECR2[(ECR: taskflow-backend)]
    S3[(S3: taskflow-tfstate-226680475141)]
  end

  User((Users)) -->|HTTP/HTTPS| NLB --> Ingress --> SVCF --> FE
  FE -->|/api| SVCB --> BE
  BE -->|SQL| PG
  FE -. pulls .-> ECR1
  BE -. pulls .-> ECR2
  Terraform[(Terraform)] -->|state| S3
  Terraform -->|provisions| AWS
```

### How to read this
- Users reach the internet-facing NLB created by Kubernetes `Ingress`/`Service` of type `LoadBalancer`.
- The Ingress forwards to the frontend `Service`/Pods; the frontend calls the backend `Service`.
- The backend talks to Postgres running inside the cluster (swap to RDS later if needed).
- Docker images are stored in ECR and pulled by the cluster when Pods start.
- Terraform provisions AWS (EKS, VPC, ECR, IAM, etc.) and stores state in S3 for team consistency.


