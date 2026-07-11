# Test Infra LocalStack

Sample infrastructure on **LocalStack (free)** with Terraform, split into **shared / network / backend** projects and **dev / staging** environments.

**CI architecture (default)**

```
Git Push
   │
   ▼
GitHub Actions
   │
   ├── Start LocalStack (Docker Compose on the runner)
   └── Terraform CLI (plan/apply) + local terraform.tfstate
           │
           ▼
      LocalStack (:4566 on the job network — not exposed to the internet)
```

Optional: Terraform Cloud for remote state only (`BACKEND=cloud`, workspaces must be **execution_mode=local**). Org: **`ExperimentTerraform`**.

## Workspace map (optional TFC)

| TFC project | Workspace (dev) | Workspace (staging) |
|---|---|---|
| `testinfra-shared` | `testinfra-shared-dev` | `testinfra-shared-staging` |
| `testinfra-network` | `testinfra-network-dev` | `testinfra-network-staging` |
| `testinfra-backend` | `testinfra-backend-dev` | `testinfra-backend-staging` |

Apply order per environment: **shared → network → backend**

## Quick start (recommended)

```bash
chmod +x scripts/*.sh
./scripts/up.sh
./scripts/use-local-backend.sh           # default: local tfstate (no TFC remote apply)
./scripts/env.sh staging apply           # includes verify-apply.sh
./scripts/verify-apply.sh staging        # re-run checks anytime
```

### Optional: Terraform Cloud remote state

```bash
export TF_TOKEN_app_terraform_io="..."
./scripts/use-tfc-backend.sh             # enforces execution_mode=local
./scripts/env.sh staging apply
```

If you see `Preparing the remote apply...`, the workspace is still **remote** — run `./scripts/ensure-tfc-local-execution.sh` or switch back with `./scripts/use-local-backend.sh`.

## GitHub Actions

1. Push to `main` → plan+apply **staging**; PRs → **plan** only
2. Manual runs: **Actions → Terraform LocalStack → Run workflow**
3. Optional TFC: set secret `TF_TOKEN_app_terraform_io` and change workflow `BACKEND` to `cloud`

Workflow file: [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml)

## Documentation

| Doc | Contents |
|---|---|
| [docs/STEP_BY_STEP.md](docs/STEP_BY_STEP.md) | Local & CI apply/destroy, optional TFC, troubleshooting |
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
    ├── tfc-bootstrap/          # optional: creates TFC projects + workspaces
    └── live/
        ├── _templates/
        ├── dev/{shared,network,backend}/
        └── staging/{shared,network,backend}/
```

## Notes

- LocalStack endpoint: `http://localhost:4566` (dummy creds `test` / `test`)
- Default state backend is **local** (avoids TFC remote apply, which cannot reach LocalStack)
- Not included on LocalStack free: Amplify, CloudFront, WAF, RDS, ElastiCache, OpenSearch, ECS
- If using TFC: workspaces **must** use `execution_mode = "local"`
