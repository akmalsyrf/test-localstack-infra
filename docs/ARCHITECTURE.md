# Architecture

## Runtime flow (GitHub Actions)

```
                    Git Push / PR / workflow_dispatch
                                   │
                                   ▼
                           GitHub Actions runner
                                   │
                 ┌─────────────────┴─────────────────┐
                 │                                   │
                 ▼                                   ▼
        docker compose up                  Terraform CLI
        (LocalStack container)             init → plan/apply
                 │                         (local tfstate by default)
                 │                                   │
                 └─────────────────┬─────────────────┘
                                   ▼
                         LocalStack APIs
                      http://localhost:4566
                   (runner-local; not public)
```

Optional: set `BACKEND=cloud` for Terraform Cloud remote state. Workspaces must use
`execution_mode=local` — TFC agents cannot reach LocalStack or parent-dir modules.

## Responsibilities

| Component | Role |
|---|---|
| **GitHub Actions** | Orchestrates the job: starts LocalStack, runs Terraform CLI |
| **LocalStack** | Emulates AWS APIs used by this repo (S3, IAM, EC2, Lambda, API GW, SNS/SQS, …) |
| **Terraform CLI** | Plans and applies configuration against LocalStack |
| **Terraform Cloud** | Optional remote state only (`BACKEND=cloud`, `execution_mode=local`) |

## Terraform projects (per environment)

| Project | Resources |
|---|---|
| **shared** | S3 buckets, Secrets Manager, SSM, IAM role/instance profile |
| **network** | VPC, subnets, IGW, security group |
| **backend** | EC2 (mocked), CloudWatch log group, SNS/SQS, Lambda, API Gateway |

Cross-stack reads (backend → shared/network):

- **TFC mode** (`tfc_organization = "ExperimentTerraform"`): `tfe_outputs`
- **Local mode** (`tfc_organization = ""`): `terraform_remote_state` on sibling `terraform.tfstate` files

## Environments

| Env | VPC CIDR | Resource prefix |
|---|---|---|
| `dev` | `10.3.0.0/16` | `testinfra-dev` |
| `staging` | `10.1.0.0/16` | `testinfra-stg` |

## Security notes for CI

- LocalStack binds to the Actions job network (`localhost:4566`). It is **not** published to the public internet.
- Dummy AWS keys (`test`/`test`) are only valid inside LocalStack.
- The only secret required for CI is `TF_TOKEN_app_terraform_io` (Terraform Cloud API token).
