# Scripts

Entry points for LocalStack + Kind + Terraform workflows in this repo.

## Quick Start

```bash
chmod +x scripts/*/*.sh
./scripts/lifecycle/up.sh
./scripts/lifecycle/env.sh staging apply
./scripts/checks/verify-apply.sh staging
```

## Catalog

| Category | Script | Purpose |
|---|---|---|
| **lifecycle** | `lifecycle/up.sh` | Start Kind (unless `SKIP_KIND=1`) then LocalStack |
| | `lifecycle/env.sh` | Sync live stacks, plan/apply/destroy one env |
| | `lifecycle/sync-live.sh` | Generate `terraform/live/{dev,staging,production}` from templates |
| | `lifecycle/apply-all.sh` | Apply staging → production → dev |
| | `lifecycle/destroy-all.sh` | Destroy production → staging → dev |
| **backend** | `backend/use-local-backend.sh` | Switch live stacks to local tfstate |
| | `backend/use-s3-backend.sh` | Bootstrap LocalStack S3+DynamoDB lock; sync `BACKEND=s3` |
| | `backend/use-tfc-backend.sh` | Sync `BACKEND=cloud` + enforce TFC `execution_mode=local` |
| | `backend/ensure-tfc-local-execution.sh` | Force TFC workspaces to local execution |
| **kind** | `kind/kind-up.sh` | Create Kind cluster + metrics-server + kubeconfig |
| | `kind/kind-down.sh` | Delete Kind cluster |
| **checks** | `checks/verify-apply.sh` | Post-apply verification (`tests/verify/*.sh`) |
| | `checks/check-drift.sh` | `terraform plan -detailed-exitcode` per stack (retry 3×) |
| | `checks/check-localstack-latency.sh` | Fail fast if LocalStack is unhealthy/slow (CI) |
| **observability** | `observability/observability-up.sh` | Grafana OSS + Loki + Alloy (local-dev; not in CI) |
| | `observability/observability-down.sh` | Tear down observability stack (`down -v`) |
| **debug** | `debug/portainer-up.sh` | Portainer CE via Compose profile `debug` (not in CI) |
| | `debug/portainer-down.sh` | Stop Portainer (keeps admin volume) |

## Layout

```
scripts/
├── README.md
├── lifecycle/
├── backend/
├── kind/
├── checks/
├── observability/
└── debug/
```

See also: [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md), [docs/STEP_BY_STEP.md](../docs/STEP_BY_STEP.md).
