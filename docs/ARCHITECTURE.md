# Architecture

## Runtime flow (local / GitHub Actions)

### Local (one-command DX)

`./scripts/up.sh` still starts **Kind first**, then LocalStack, then bridges
networks — fine on a laptop with enough CPU/RAM.

### CI sequencing (Kind deferred) {#ci-sequencing-kind-deferred}

On small GitHub-hosted runners, Kind (3 nodes + metrics-server) and LocalStack
(`LAMBDA_RUNTIME_EXECUTOR=docker` → host `docker.sock`) contend for the same
Docker daemon and CPU. That starvation made even `aws_s3_bucket` hang for nearly
an hour during the first stack. CI therefore:

1. Start **LocalStack alone** (`SKIP_KIND=1 ./scripts/up.sh`) + latency smoke  
2. Terraform **shared → network → backend** (no Kind)  
3. Start **Kind** + bridge LocalStack onto the `kind` network + latency smoke  
4. Terraform **eks** + `verify-apply.sh`


```mermaid
flowchart TD
  A[GitHub Actions] --> L[LocalStack only]
  L --> S[Terraform shared / network / backend]
  S --> K[Kind + metrics-server]
  K --> E[Terraform eks]
  E --> V[verify-apply.sh]
```

```
                    GitHub Actions (CI)
                                   │
                                   ▼
                         docker compose up  (LocalStack alone)
                                   │
                         latency smoke (s3 ls < 5s)
                                   │
              Terraform: shared → network → backend
                                   │
                         kind-up.sh (pods use host.docker.internal → :4566)
                                   │
                         latency smoke again
                                   │
                         Terraform: eks → verify
```

Local `./scripts/up.sh` flow (unchanged convenience):

```
        kind create cluster                 docker compose up
        (testinfra-eks)                     (LocalStack free)
                 │                                   │
                 └─────────────────┬─────────────────┘
                                   ▼
                         Terraform CLI (all stacks)
              shared → network → backend → eks
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
| **backend** | EC2 (IMDSv2, encrypted EBS) in private subnet, CW log group, SNS→SQS (+DLQ, SSE-SQS), Lambda (DLQ, reserved concurrency, X-Ray), API Gateway (access logs, throttle, usage plan), CW alarms → ops SNS (+ SQS alerts queue subscription) |
| **eks** | EKS-shaped IAM + Kind mirror record + sample nginx (2 replicas, probes, resources; LocalStack free: no `aws_eks_*`) |

Cross-stack reads (backend/eks → network/shared):

- **TFC mode** (`tfc_organization = "ExperimentTerraform"`): `tfe_outputs`
- **Local mode** (`tfc_organization = ""`): `terraform_remote_state` on sibling `terraform.tfstate` files
- **S3 mode** (`BACKEND=s3`): `terraform_remote_state` against LocalStack S3 keys `shared|network/terraform.tfstate`

## Environments

| Env | VPC CIDR | Resource prefix | EKS cluster name | NodePort | Log retention | SQS depth alarm | Secret recovery |
|---|---|---|---|---|---|---|---|
| `dev` | `10.3.0.0/16` | `testinfra-dev` | `testinfra-eks-dev` | 30081 | 14d | 100 | 7d |
| `staging` | `10.1.0.0/16` | `testinfra-stg` | `testinfra-eks-staging` | 30080 | 14d | 100 | 7d |
| `production` | `10.2.0.0/16` | `testinfra-prod` | `testinfra-eks-production` | 30082 | **30d** | **50** | **30d** |

All three tiers are generated by `scripts/sync-live.sh` from `terraform/live/_templates` (same modules/shape). Production differs only via tfvars knobs above (longer retention, stricter SQS depth, longer secret recovery) plus naming/CIDR — not divergent Terraform code paths.

CI: `push`/`pull_request` still target **staging** (and plan on PRs). **production** apply is manual only (`workflow_dispatch` on `terraform.yml`).

## Production-readiness additions (still free-tier)

Hardening that stays within LocalStack Community coverage:

| Area | What we added |
|---|---|
| **State safety** | Opt-in `BACKEND=s3` (S3 + DynamoDB lock) via `terraform/s3-bootstrap` + `use-s3-backend.sh` |
| **Security** | S3 SSE-AES256 + versioning + 30d noncurrent lifecycle; scoped IAM logs ARN; EC2 IMDSv2 + encrypted root; SQS SSE; Secrets recovery window 7d; CI tflint/checkov |
| **Availability** | SQS DLQ + redrive; Lambda DLQ + reserved concurrency; EKS sample replicas=2 + resources + liveness; S3 Gateway VPC endpoint |
| **Observability** | CW dashboard + alarms (EC2 status, Lambda errors, SQS depth) → SNS ops topic → SQS alerts queue; Lambda/API X-Ray config; API access logs; log retention 14d (30d production). Optional local-only Grafana/Loki/Portainer — see below. |

## Observability & debugging (optional, local-dev only)

Three layers — only the first is always applied by Terraform / safe in CI:

| Layer | What | When it runs |
|---|---|---|
| **1. CloudWatch Dashboard** | `aws_cloudwatch_dashboard` on the backend stack (EC2 / Lambda / SQS / API GW widgets). Zero runtime footprint. | Always (Terraform). Fine in CI. |
| **2. Grafana + Loki + Promtail** | OSS log UI for Kind/Docker containers. | Opt-in: `./scripts/observability-up.sh` → `docker-compose.observability.yml`. **Never** started by `up.sh` or CI. |
| **3. Portainer CE** | Docker + Kubernetes debug UI (`profiles: ["debug"]`). | Opt-in: `./scripts/portainer-up.sh`. **Never** started by `up.sh` or CI. |

**Why excluded from CI:** small GitHub runners already contended between Kind and LocalStack ([CI sequencing](#ci-sequencing-kind-deferred)). Adding Grafana/Loki/Portainer would worsen that hang risk. Keep them laptop-only.

```bash
./scripts/observability-up.sh    # Grafana http://localhost:3000 (admin/admin)
./scripts/observability-down.sh  # down -v
./scripts/portainer-up.sh        # Portainer http://localhost:9000
./scripts/portainer-down.sh      # stop only (keeps admin volume)
```

**Portainer + Kind:** Environments → Add → Kubernetes → Import kubeconfig → `.kube/kind-config`. Portainer sees all host Docker containers (including `testinfra-localstack` and Kind nodes) via the shared `docker.sock` — intentional.

**X-Ray note:** Lambda/API set `tracing_config { mode = "Active" }` / `xray_tracing_enabled`, and `SERVICES` includes `xray`. On LocalStack Community **4.3**, `GetTraceSummaries` returns `InternalFailure` (“not yet implemented or pro feature”) — so **trace retrieval is not verifiable here**. `tests/verify/80_functional.sh` records that finding; treat X-Ray as configure-only until Community coverage changes (or you move to real AWS / Pro).

## Ops alerts: SNS → SQS (LocalStack-verifiable)

CloudWatch alarms publish to `aws_sns_topic.ops_alerts`. That topic has an **SQS subscription** (`ops_alerts_queue`) so alarms land somewhere queryable inside LocalStack:

```mermaid
flowchart LR
  alarms[CW alarms] --> sns[ops_alerts SNS]
  sns --> sqs[ops_alerts_queue SQS]
```

Email / Slack / PagerDuty cannot be verified end-to-end on free LocalStack (no real external delivery). **Swap-in point for real AWS:** replace the SQS subscription with the real protocol/endpoint; keep the same SNS topic and alarm `AlarmActions`. Code comments on the subscription call this out.

## Scheduled drift check

Workflow: [`.github/workflows/drift-check.yml`](../.github/workflows/drift-check.yml) (`cron` daily + `workflow_dispatch`). Shared logic: [`scripts/check-drift.sh`](../scripts/check-drift.sh) (also called from `verify-apply.sh`).

**Limitation:** GitHub runners and LocalStack here are ephemeral. There is no multi-day persisted infra to compare against between jobs. The scheduled job re-applies fresh, then asserts `terraform plan` is empty — the same 0-drift-after-apply safety net as per-run verify, on a cadence. True out-of-band drift detection needs a persistent LocalStack (or real AWS) with durable state; neither is free on ephemeral CI. Failures notify via GitHub’s built-in workflow-failure emails.

**CI sequencing (same as `terraform.yml`):** LocalStack alone → S3 bootstrap → apply `shared/network/backend` while host `:4566` works → Kind → apply `eks`. On Linux, attaching LocalStack to the Kind network can break published `:4566`; `scripts/env.sh` then switches the provider **and** re-bakes S3 `backend` block endpoints to the container IP (`init -reconfigure`). Sibling `terraform_remote_state` reads use `var.localstack_endpoint` (not a baked URL) so the same switch covers network/backend state fetches during `eks` apply. Default `terraform.yml` stays on `BACKEND=local` and is unaffected.
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
  ls[testinfra-localstack :4566 on host]
  discover[data.external localstack-network-info.sh]
  discover -->|host.docker.internal IPv4| ep[Endpoints localstack:4566]
  ep --> svc[headless Service localstack]
  svc --> secret[Secret localstack-creds]
  secret --> job[Job smoke-test-messaging]
  job -->|AWS_ENDPOINT_URL| ls
```

**Startup order:**

**Local (`./scripts/up.sh`):** Kind → LocalStack → full apply.

**CI:** LocalStack alone → apply shared/network/backend → Kind → apply eks.
Only the `eks` stack needs Kind; deferring it avoids Docker/CPU contention on
small runners (see [CI sequencing](#ci-sequencing-kind-deferred)).

Bridge discovery attaches LocalStack to the Docker `kind` network and points
Endpoints at that IP. On Linux CI that attach often breaks host `:4566` publish;
`scripts/env.sh` then switches `TF_VAR_localstack_endpoint` to LocalStack's
compose-network IP so Terraform keeps working.

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

  Note over U,L: CI starts LocalStack first; Kind deferred until eks
  U->>L: docker compose up (SKIP_KIND in CI)
  U->>T: apply shared / network / backend
  U->>K: kind-up.sh (CI only after early stacks)
  U->>T: apply eks (IAM + Kind workload; bridge via host.docker.internal)
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
