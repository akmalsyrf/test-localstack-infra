# Step-by-step guide

How to apply / destroy locally, bootstrap **Terraform Cloud** (`ExperimentTerraform`), and run **GitHub Actions** with LocalStack.

## Prerequisites

- Docker Desktop (or Docker Engine)
- Terraform >= 1.5
- AWS CLI v2 (`aws`) — used by `scripts/verify-apply.sh`
- `curl`, `zip`, `python3`
- A Terraform Cloud account and organization named **`ExperimentTerraform`** (or change `TFC_ORG`)
- A TFC API token (User or Team token with permission to manage state / workspaces)

---

## A. One-time: bootstrap Terraform Cloud

Creates 3 projects and 6 workspaces with **`execution_mode = local`** (state in TFC, runs on your machine / Actions).

```bash
cd terraform/tfc-bootstrap
cp terraform.tfvars.example terraform.tfvars
# organization = "ExperimentTerraform"  (default)

export TFE_TOKEN="xxxxx.atlasv1.xxxxx"   # same value you will store as TF_TOKEN_app_terraform_io
# or: export TF_TOKEN_app_terraform_io="..."

terraform init
terraform apply
```

Expected `workspace_map`:

| Key | Workspace |
|---|---|
| `shared/dev` | `testinfra-shared-dev` |
| `shared/staging` | `testinfra-shared-staging` |
| `network/dev` | `testinfra-network-dev` |
| `network/staging` | `testinfra-network-staging` |
| `backend/dev` | `testinfra-backend-dev` |
| `backend/staging` | `testinfra-backend-staging` |

Verify in the TFC UI that each workspace shows **Execution mode: Local**.

If a workspace was auto-created by `terraform init` before bootstrap (default is **remote**), fix it:

```bash
export TF_TOKEN_app_terraform_io="..."
./scripts/ensure-tfc-local-execution.sh
# or re-apply bootstrap:
cd terraform/tfc-bootstrap && terraform apply
```

---

## B. GitHub repository secrets

In the GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|---|---|
| `TF_TOKEN_app_terraform_io` | Your Terraform Cloud API token |

Terraform CLI automatically picks up `TF_TOKEN_app_terraform_io` for `app.terraform.io`.

You can add this secret later; the workflow fails fast if it is missing.

---

## C. Local development with LocalStack + TFC state

```bash
cd localstack-infra
chmod +x scripts/*.sh

./scripts/up.sh                          # LocalStack on :4566
export TF_TOKEN_app_terraform_io="..."   # required for cloud backend
./scripts/use-tfc-backend.sh             # sync live/* with cloud {} blocks

./scripts/env.sh staging plan
./scripts/env.sh staging apply   # ends with scripts/verify-apply.sh
./scripts/env.sh dev apply
```

Or verify an already-applied environment:

```bash
./scripts/verify-apply.sh staging
```

Destroy (reverse order inside the script):

```bash
./scripts/env.sh staging destroy
./scripts/env.sh dev destroy
docker compose down
```

### Local state only (no TFC)

```bash
./scripts/use-local-backend.sh
./scripts/env.sh staging apply
```

---

## D. GitHub Actions behaviour

Workflow: `.github/workflows/terraform.yml`

| Event | Environment | Action |
|---|---|---|
| `pull_request` | `staging` | `plan` |
| `push` to `main`/`master` | `staging` | `apply` |
| `workflow_dispatch` | chosen | `plan` / `apply` / `destroy` |

What the job does:

1. Starts LocalStack via `docker compose up -d --wait` (Docker socket available for Lambda)
2. Syncs `terraform/live/*` with **cloud** backend → org `ExperimentTerraform`
3. Runs Terraform CLI `init` + `plan`/`apply`/`destroy` for `shared` → `network` → `backend`
4. On apply: runs `scripts/verify-apply.sh` (outputs, AWS resource existence, SNS→SQS, Lambda invoke, API smoke, drift check)
5. Tears down LocalStack (`docker compose down -v`)

Nothing from LocalStack is exposed outside the runner.

---

## E. Manual workflow run

1. GitHub → **Actions** → **Terraform LocalStack** → **Run workflow**
2. Pick `environment` (`staging` / `dev`) and `action` (`plan` / `apply` / `destroy`)
3. Run

---

## F. Apply order & remote state

```
shared ──► network ──► backend
                         │
                         ├── tfe_outputs → testinfra-shared-<env>
                         └── tfe_outputs → testinfra-network-<env>
```

`terraform/live/<env>/backend/terraform.tfvars` must set:

```hcl
tfc_organization = "ExperimentTerraform"
```

(when using the cloud backend). `scripts/sync-live.sh` writes this automatically for `BACKEND=cloud`.

Workspaces share remote state via `global_remote_state = true` in `tfc-bootstrap`.

---

## G. Cheat sheet

```bash
# LocalStack
./scripts/up.sh
docker compose down -v

# Sync backends
./scripts/use-tfc-backend.sh              # cloud / ExperimentTerraform
./scripts/use-local-backend.sh            # local tfstate
TFC_ORG=OtherOrg ./scripts/use-tfc-backend.sh OtherOrg

# Per environment
./scripts/env.sh staging apply
./scripts/env.sh staging destroy
./scripts/env.sh dev plan

# Bootstrap TFC
cd terraform/tfc-bootstrap && terraform apply
```

---

## H. Troubleshooting

| Symptom | Fix |
|---|---|
| `Unauthorized` / TFC login errors | Set `TF_TOKEN_app_terraform_io` (Actions secret or local export) |
| Workspace not found | Run `terraform/tfc-bootstrap` apply; check org name `ExperimentTerraform` |
| `Preparing the remote apply...` / `Unreadable module directory ../../../modules` | Workspace is still **remote**. Run `./scripts/ensure-tfc-local-execution.sh`, confirm with `./scripts/assert-tfc-local-execution.sh`, then `terraform init` (or `./scripts/env.sh staging apply`). UI: Execution Mode → **Local (custom)** — not "Project default". |
| `Invalid command-line option` for `-reconfigure` with Cloud | Expected with `terraform { cloud {} }`. Use plain `terraform init` (no `-reconfigure`). |
| Plan runs on TFC agents and cannot reach LocalStack | Same as above — must be **Local** execution |
| `connection refused :4566` | Start LocalStack (`./scripts/up.sh` or wait for compose health in CI) |
| `tfe_outputs` empty | Apply `shared` and `network` first; confirm remote state sharing |
| Backend type changed local ↔ cloud | `terraform init -reconfigure` or `-migrate-state` |
| Lambda create fails in CI | Ensure compose mounts docker.sock (default in this repo) |
| Secret missing in Actions | Add `TF_TOKEN_app_terraform_io` under repo secrets |

---

## I. Migrating existing local state into TFC

If you already applied with `BACKEND=local`:

```bash
export TF_TOKEN_app_terraform_io="..."
./scripts/use-tfc-backend.sh

for env in staging dev; do
  for project in shared network backend; do
    terraform -chdir=terraform/live/$env/$project init -migrate-state
  done
done
```

Confirm state appears under each workspace in the TFC UI, then use GitHub Actions as usual.
