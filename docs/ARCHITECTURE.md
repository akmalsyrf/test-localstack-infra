# Architecture

## Runtime flow (local / GitHub Actions)

```mermaid
flowchart TD
  A[Git push / PR / workflow_dispatch<br/>or local ./scripts/up.sh] --> B[Kind cluster<br/>testinfra-eks]
  A --> C[LocalStack container<br/>:4566]
  E[Terraform CLI<br/>shared → network → backend → eks] --> C
  E -->|kubernetes provider + IAM| B
  E -->|aws_* APIs| C
```

```
                    Git Push / PR / workflow_dispatch  (or local scripts)
                                   │
                 ┌─────────────────┴─────────────────┐
                 ▼                                   ▼
        kind create cluster                 docker compose up
        (testinfra-eks)                     (LocalStack free)
                 │                                   │
                 │  .kube/kind-config                │
                 │  (host kubectl / TF k8s)          │
                 └─────────────────┬─────────────────┘
                                   ▼
                         Terraform CLI (local tfstate by default)
              shared → network → backend → eks
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
        LocalStack APIs     IAM roles for EKS      kubernetes provider
        :4566               (mirror)               → Kind workloads
```

State backends:

- `BACKEND=local` (default) — `terraform.tfstate` on disk
- `BACKEND=s3` — S3 bucket `tfstate-<project>-<env>` + DynamoDB lock table
  `tflock-<project>-<env>` on LocalStack (bootstrap via `./scripts/use-s3-backend.sh`)
- `BACKEND=cloud` — Terraform Cloud remote state; workspaces must use
  `execution_mode=local` — TFC agents cannot reach LocalStack, Kind, or parent-dir modules

## Kind ↔ LocalStack EKS mirror

LocalStack **community** does not implement the EKS API (Pro-only). This repo mirrors the
usual LocalStack/AWS EKS Terraform shape on **Kind** instead:

| Real AWS / LocalStack Pro EKS | This repo (free) |
|---|---|
| `aws_eks_cluster` | Logical cluster name + synthetic ARN + Kind control plane |
| `aws_eks_node_group` | Logical node group + Kind worker node(s) |
| Cluster / node IAM roles | `aws_iam_role` on LocalStack (same trust policies) |
| Workloads | Terraform **kubernetes** provider → Kind |
| Sample exposure | NodePort `30080` (Kind `extraPortMappings`) |
| Cluster record | ConfigMap `eks-mirror-<name>` in Kind `default` ns |

## Responsibilities

| Component | Role |
|---|---|
| **GitHub Actions / scripts** | Orchestrates Kind + LocalStack + Terraform CLI; static analysis (tflint/checkov) |
| **Kind** | Real local Kubernetes (EKS stand-in) |
| **LocalStack** | Emulates AWS APIs (S3, IAM, EC2, Lambda, API GW, SNS/SQS, DynamoDB, X-Ray, …) |
| **Terraform CLI** | Plans/applies against LocalStack + Kind |
| **Terraform Cloud** | Optional remote state only (`BACKEND=cloud`, `execution_mode=local`) |
| **S3+DynamoDB (LocalStack)** | Optional remote state (`BACKEND=s3`) |

## Terraform projects (per environment)

```mermaid
flowchart LR
  shared[shared<br/>S3, Secrets, IAM] --> network[network<br/>VPC, subnets, SG, S3 VPCE]
  network --> backend[backend<br/>EC2, CW, SNS/SQS+DLQ, Lambda, APIGW, alarms]
  network --> eks[eks<br/>EKS cluster/nodegroup + sample app]
```

| Project | Resources |
|---|---|
| **shared** | S3 (+ SSE-S3, versioning, lifecycle), Secrets Manager (recovery window), IAM role/instance profile (scoped CW logs) |
| **network** | VPC (DNS on), 3 public + 3 private subnets, IGW, public/private RTs, **S3 Gateway VPC endpoint**, SG (443 + 3000) |
| **backend** | EC2 (IMDSv2, encrypted EBS) in private subnet, CW log group (14d), SNS→SQS (+DLQ, SSE-SQS), Lambda (DLQ, reserved concurrency, X-Ray), API Gateway (access logs, throttle, usage plan), CW alarms → ops SNS |
| **eks** | EKS-shaped IAM + Kind mirror record + sample nginx (2 replicas, probes, resources; LocalStack free: no `aws_eks_*`) |

Cross-stack reads (backend/eks → network/shared):

- **TFC mode** (`tfc_organization = "ExperimentTerraform"`): `tfe_outputs`
- **Local mode** (`tfc_organization = ""`): `terraform_remote_state` on sibling `terraform.tfstate` files
- **S3 mode** (`BACKEND=s3`): `terraform_remote_state` against LocalStack S3 keys `shared|network/terraform.tfstate`

## Environments

| Env | VPC CIDR | Resource prefix | EKS cluster name |
|---|---|---|---|
| `dev` | `10.3.0.0/16` | `testinfra-dev` | `testinfra-eks-dev` |
| `staging` | `10.1.0.0/16` | `testinfra-stg` | `testinfra-eks-staging` |

## Production-readiness additions (still free-tier)

Hardening that stays within LocalStack Community coverage:

| Area | What we added |
|---|---|
| **State safety** | Opt-in `BACKEND=s3` (S3 + DynamoDB lock) via `terraform/s3-bootstrap` + `use-s3-backend.sh` |
| **Security** | S3 SSE-AES256 + versioning + 30d noncurrent lifecycle; scoped IAM logs ARN; EC2 IMDSv2 + encrypted root; SQS SSE; Secrets recovery window 7d; CI tflint/checkov |
| **Availability** | SQS DLQ + redrive; Lambda DLQ + reserved concurrency; EKS sample replicas=2 + resources + liveness; S3 Gateway VPC endpoint |
| **Observability** | CW alarms (EC2 status, Lambda errors, SQS depth) → SNS ops topic; Lambda/API X-Ray; API access logs; log retention 14d |
| **Scalability** | API GW usage plan + stage throttling; Kind metrics-server + HPA (min 2 / max 4) |

### Still NOT production-ready (out of scope / Pro or paid)

- Real multi-AZ **NAT Gateway** routing
- Real **EKS** control plane (Kind mirror only)
- **RDS** / ElastiCache / OpenSearch
- **WAF**, CloudFront, Shield
- Secrets Manager **automatic rotation** Lambda
- Customer-managed **KMS** with full rotation policy
- ASG + ALB self-healing (ASG APIs exist, but ALB health-check simulation is incomplete on Community — single EC2 kept)
- Real **IRSA/OIDC** validation (no EKS OIDC issuer on LocalStack Community)
- NetworkPolicy enforcement (Kind default CNI kindnet does not enforce; Calico swap skipped for CI stability)

## Kind ↔ LocalStack messaging bridge

Workloads on Kind reach LocalStack SQS/SNS without LocalStack Pro or a real AWS account:

```mermaid
flowchart LR
  up[scripts/up.sh] --> kindNet[Docker network: kind]
  up --> ls[testinfra-localstack]
  up -->|docker network connect| bridge[LS on kind network]
  bridge --> discover[data.external localstack-network-info.sh]
  discover --> ep[Endpoints localstack:4566]
  ep --> svc[headless Service localstack]
  svc --> secret[Secret localstack-creds]
  secret --> job[Job smoke-test-messaging]
  job -->|AWS_ENDPOINT_URL| sqs[SQS / SNS on LocalStack]
```

**Startup order (fragile if reversed):**

1. `kind-up.sh` — creates Kind + Docker network `kind` + metrics-server  
2. `docker compose up` — starts LocalStack  
3. `docker network connect kind testinfra-localstack` (idempotent in `up.sh`)  
4. `terraform apply` eks — discovers IP, creates Service/Endpoints, runs smoke Job  

If LocalStack is not on the `kind` network before eks apply, `data.external.localstack_network` fails.

**IRSA-forward-compatible pattern**

| Piece | Today (Kind + LocalStack) | Real EKS later |
|---|---|---|
| `aws_iam_role` + scoped SQS/SNS policy (`iam-eks-workload`) | Created; trust is placeholder | Keep |
| ServiceAccount annotation `eks.amazonaws.com/role-arn` | Present but inert | Keep |
| `enable_irsa_oidc` / `oidc_provider_arn` | `false` / empty | Set to cluster OIDC |
| Secret `localstack-creds` | **LOCAL-ONLY bypass** (`test`/`test` + `AWS_ENDPOINT_URL`) | **Delete** |
| headless Service + Endpoints + `localstack-network-info.sh` | Bridge to Docker IP | **Delete** |
| Job `smoke-test-messaging` | Proves SNS→SQS via bridge | Retarget to real AWS endpoints / remove |

## Apply / verify sequence

```mermaid
sequenceDiagram
  participant U as Operator / CI
  participant K as Kind
  participant L as LocalStack
  participant T as Terraform
  participant V as verify-apply.sh

  U->>K: kind-up.sh
  U->>L: docker compose up
  U->>T: sync-live + apply shared
  U->>T: apply network
  U->>T: apply backend
  U->>T: apply eks (IAM + Kind workload)
  T->>L: Create IAM roles (EKS-shaped)
  T->>K: Namespace / Deployment / Service / ConfigMap
  U->>V: naming, AWS API, Kind, functional, drift checks
```

## Security notes for CI

- LocalStack binds to the Actions job network (`localhost:4566`). It is **not** published to the public internet.
- Dummy AWS keys (`test`/`test`) are only valid inside LocalStack.
- Kind kubeconfig lives at `.kube/kind-config` (used by Terraform kubernetes provider + verify).
- The only secret required for optional TFC is `TF_TOKEN_app_terraform_io`.
- Static analysis (`tflint`, `checkov`) runs before plan/apply and does not need LocalStack.
