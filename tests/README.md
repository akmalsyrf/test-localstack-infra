# Verify-apply test modules

Post-apply checks for LocalStack (+ Kind/EKS), split out of the former monolithic
`scripts/checks/verify-apply.sh`.

## Layout

| File | Responsibility |
|---|---|
| `lib.sh` | Shared helpers (`ok`/`fail`, AWS/Terraform helpers, backend init) |
| `10_health.sh` | LocalStack health + latency |
| `20_outputs.sh` | Backend init + collect Terraform outputs (abort if incomplete) |
| `30_naming.sh` | Naming / CIDR conventions |
| `40_shared.sh` | Shared stack (S3, Secrets, IAM) |
| `50_network.sh` | Network stack (VPC, subnets, SG, VPCE) |
| `60_backend.sh` | Backend stack (EC2, SQS/SNS, Lambda, API GW, alarms) |
| `70_eks.sh` | EKS mirror + Kind workloads |
| `80_functional.sh` | SNS→SQS, Lambda invoke, API smoke |
| `90_s3_remote_state.sh` | S3/DynamoDB remote-state bootstrap checks |
| `95_drift.sh` | Delegates to `scripts/checks/check-drift.sh` |

## How to run

```bash
./scripts/checks/verify-apply.sh staging   # sources tests/verify/*.sh in order
BACKEND=s3 ./scripts/checks/verify-apply.sh staging
```

Override the tests directory if needed: `VERIFY_TESTS_DIR=/path/to/tests/verify`.

Modules are **sourced** (not executed as subprocesses) so they share counters and
Terraform output variables with the runner.
