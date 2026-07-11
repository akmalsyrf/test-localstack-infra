# Step-by-step guide

How to apply / destroy with **LocalStack**, optionally use **Terraform Cloud**, and run **GitHub Actions**.

## Prerequisites

- Docker Desktop (or Docker Engine)
- Terraform >= 1.5
- AWS CLI v2 (`aws`) — used by `scripts/verify-apply.sh`
- `curl`, `zip`, `python3`
- Optional: Terraform Cloud org + API token (only if `BACKEND=cloud`)

---

## Recommended: LocalStack + local state

```bash
chmod +x scripts/*.sh
./scripts/up.sh
./scripts/use-local-backend.sh
./scripts/env.sh staging apply
```

If LocalStack is wedged (SNS/SQS hangs), reset it:

```bash
docker compose down -v && ./scripts/up.sh
./scripts/env.sh staging apply
```

Destroy:

```bash
./scripts/env.sh staging destroy
docker compose down -v
```

---

## Optional: Terraform Cloud remote state

Workspaces must use **execution_mode=local** (LocalStack is not reachable from TFC agents).

```bash
cd terraform/tfc-bootstrap && terraform init && terraform apply
export TF_TOKEN_app_terraform_io="..."
./scripts/use-tfc-backend.sh
./scripts/env.sh staging apply
```

If you see `Preparing the remote apply...`, run `./scripts/ensure-tfc-local-execution.sh` or switch to `./scripts/use-local-backend.sh`.

---

## GitHub Actions

Default `BACKEND=local`. PRs → plan staging; push to main → apply staging.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| SNS CreateTopic 501 / "not yet implemented or pro" | Do **not** set `PROVIDER_OVERRIDE_SNS=asf` on LocalStack free. Reset: `docker compose down -v && ./scripts/up.sh` |
| SNS hang / SQS URL format errors | Compose uses `SQS_ENDPOINT_STRATEGY=off` (Terraform-compatible). Reset LocalStack then re-apply. |
| `Preparing the remote apply...` / missing `../../../modules` | Workspace is remote → `ensure-tfc-local-execution.sh` or local backend |
| `InvalidPermission.Duplicate` on SG rules | Re-sync + apply; SG uses inline rules with `ignore_changes` |
| `connection refused :4566` | `./scripts/up.sh` |
| TFC token errors | Export `TF_TOKEN_app_terraform_io` or use `BACKEND=local` |

---

## Scripts

| Script | Purpose |
|---|---|
| `up.sh` | Start LocalStack |
| `use-local-backend.sh` | Local tfstate (default) |
| `use-tfc-backend.sh` | Optional TFC cloud state |
| `ensure-tfc-local-execution.sh` | Force TFC workspaces to local execution |
| `env.sh` | plan/apply/destroy + verify |
| `verify-apply.sh` | Post-apply checks |
| `apply-all.sh` / `destroy-all.sh` | Both envs |
