# Step-by-step guide

How to apply / destroy with **LocalStack**, optionally use **Terraform Cloud** (`ExperimentTerraform`), and run **GitHub Actions**.

## Prerequisites

- Docker Desktop (or Docker Engine)
- Terraform >= 1.5
- AWS CLI v2 (`aws`) — used by `scripts/verify-apply.sh`
- `curl`, `zip`, `python3`
- Optional: Terraform Cloud org **`ExperimentTerraform`** + API token (only if `BACKEND=cloud`)

---

## A. Recommended: LocalStack + local state

```bash
cd localstack-infra
chmod +x scripts/*.sh

./scripts/up.sh
./scripts/use-local-backend.sh
./scripts/env.sh staging apply   # verify-apply.sh runs at the end
./scripts/env.sh dev apply
```

Destroy:

```bash
./scripts/env.sh staging destroy
./scripts/env.sh dev destroy
docker compose down
```

This path never talks to TFC agents, so you will not see `Preparing the remote apply...` or missing `../../../modules`.

---

## B. Optional: Terraform Cloud remote state

TFC stores state only. Plan/apply must run on your machine / Actions (`execution_mode=local`) because LocalStack is at `localhost:4566`.

### B1. Bootstrap workspaces (once)

```bash
cd terraform/tfc-bootstrap
cp terraform.tfvars.example terraform.tfvars
export TF_TOKEN_app_terraform_io="..."
terraform init
terraform apply
```

Confirm each workspace: **Execution mode → Local (custom)**.

### B2. Apply with cloud state

```bash
export TF_TOKEN_app_terraform_io="..."
./scripts/use-tfc-backend.sh
./scripts/ensure-tfc-local-execution.sh   # also runs from use-tfc-backend / env.sh
./scripts/env.sh staging apply
```

`env.sh` forces each workspace to local **immediately before** that stack’s apply (fixes cases where only `backend` stayed remote).

If anything is still remote:

```bash
./scripts/force-workspace-local.sh testinfra-backend-staging
# UI: Workspace → Settings → General → Execution Mode → Local (custom)
# Or abandon TFC for LocalStack:
./scripts/use-local-backend.sh && ./scripts/env.sh staging apply
```

---

## C. GitHub Actions

Workflow: `.github/workflows/terraform.yml` (default `BACKEND=local`)

| Event | Environment | Action |
|---|---|---|
| `pull_request` | `staging` | `plan` |
| `push` to `main`/`master` | `staging` | `apply` |
| `workflow_dispatch` | chosen | `plan` / `apply` / `destroy` |

Optional TFC in CI: set secret `TF_TOKEN_app_terraform_io` and change workflow `env.BACKEND` to `cloud`.

---

## D. Troubleshooting

| Symptom | Fix |
|---|---|
| `Preparing the remote apply...` / `Unreadable module directory` | Workspace is **remote**. `./scripts/ensure-tfc-local-execution.sh` or `./scripts/use-local-backend.sh` |
| `Invalid command-line option` for `-reconfigure` with Cloud | Use plain `terraform init` with `cloud {}` |
| `Unauthorized` / TFC login errors | Set `TF_TOKEN_app_terraform_io` |
| Workspace not found | Run `terraform/tfc-bootstrap` apply |
| `connection refused :4566` | `./scripts/up.sh` |
| `tfe_outputs` empty | Apply `shared` + `network` first (cloud mode only) |
| Backend type changed local ↔ cloud | `BACKEND=local` or `cloud` + `./scripts/sync-live.sh`; for local use `init -reconfigure` |

---

## E. Scripts reference

| Script | Purpose |
|---|---|
| `up.sh` | Start LocalStack |
| `use-local-backend.sh` | Sync live stacks to local tfstate (default) |
| `use-tfc-backend.sh` | Sync live stacks to TFC `cloud {}` |
| `ensure-tfc-local-execution.sh` | Force all workspaces + projects to local |
| `force-workspace-local.sh` | Force one workspace + discard stuck remote runs |
| `env.sh` | plan/apply/destroy + verify |
| `verify-apply.sh` | Post-apply resource + functional checks |
