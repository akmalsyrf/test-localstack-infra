# Test Infra LocalStack

Sample infrastructure on **LocalStack (free)** with Terraform, split into **shared / network / backend** projects and **dev / staging** environments.

**CI architecture**

```
Git Push
   │
   ▼
GitHub Actions
   │
   ├── Start LocalStack (Docker Compose on the runner)
   └── Terraform CLI (plan/apply)
           │
           ▼
    Terraform Cloud
    (remote state only, execution_mode=local)
           │
           ▼
      LocalStack (:4566 on the job network — not exposed to the internet)
```

Terraform Cloud organization: **`ExperimentTerraform`**

## Workspace map

| TFC project | Workspace (dev) | Workspace (staging) |
|---|---|---|
| `testinfra-shared` | `testinfra-shared-dev` | `testinfra-shared-staging` |
| `testinfra-network` | `testinfra-network-dev` | `testinfra-network-staging` |
| `testinfra-backend` | `testinfra-backend-dev` | `testinfra-backend-staging` |

Apply order per environment: **shared → network → backend**

## Quick start (local)

```bash
chmod +x scripts/*.sh
./scripts/up.sh

# Optional: local state only (no TFC)
BACKEND=local ./scripts/sync-live.sh
./scripts/env.sh staging apply          # includes verify-apply.sh

# Default: Terraform Cloud remote state (needs token)
export TF_TOKEN_app_terraform_io="..."   # add later as a GitHub secret too
./scripts/use-tfc-backend.sh             # org ExperimentTerraform
./scripts/env.sh staging apply
./scripts/verify-apply.sh staging        # re-run checks anytime
```

## GitHub Actions

1. Create TFC workspaces (once): see [docs/STEP_BY_STEP.md](docs/STEP_BY_STEP.md)
2. Add repository secret **`TF_TOKEN_app_terraform_io`**
3. Push to `main` → plan+apply **staging**; PRs → **plan** only
4. Manual runs: **Actions → Terraform LocalStack → Run workflow**

Workflow file: [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml)

## Documentation

| Doc | Contents |
|---|---|
| [docs/STEP_BY_STEP.md](docs/STEP_BY_STEP.md) | Bootstrap TFC, local & CI apply/destroy, secrets, troubleshooting |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Diagram and component responsibilities |

## Layout

```
localstack-infra/
├── .github/workflows/terraform.yml
├── docker-compose.yml
├── docs/
├── lambda/api/
├── scripts/
└── terraform/
    ├── modules/
    ├── tfc-bootstrap/          # creates TFC projects + workspaces
    └── live/
        ├── _templates/
        ├── dev/{shared,network,backend}/
        └── staging/{shared,network,backend}/
```

## Notes

- LocalStack endpoint: `http://localhost:4566` (dummy creds `test` / `test`)
- Not included on LocalStack free: Amplify, CloudFront, WAF, RDS, ElastiCache, OpenSearch, ECS
- TFC workspaces **must** use `execution_mode = "local"` so runs happen in Actions/your laptop, not on TFC agents
