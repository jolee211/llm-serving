# Guardrails

The lab stays at zero AWS infrastructure cost between experiments. These checks use the `personal` profile only. They never use the `confiant` profile.

## Account pin

`verify-zero-cost.sh` runs `aws-preflight 4`, calls STS with `--profile personal`, and compares the account to the SHA-256 fingerprint in:

```text
~/.aws/llm-serving-account.sha256
```

The fingerprint file is mode 600. It does not contain the account number. Missing or mismatched identity exits 3 before inventory or mutation.

## Immediate zero-cost verification

```bash
AWS_PROFILE=personal ./guardrails/verify-zero-cost.sh
```

It scans every enabled region using resource APIs rather than Cost Explorer. It checks EKS, EC2, Auto Scaling, Spot requests and fleets, EBS, elastic IPs, NAT gateways, load balancers, EFS, CloudFormation, logs, Secrets Manager, customer-managed KMS keys, ECR, non-default VPCs, AWS Backup recovery points, and S3.

Exit codes:

- `0`: complete scan, no billable or residual infrastructure found
- `1`: resources found
- `2`: incomplete scan because at least one inventory call failed
- `3`: authentication, profile, or pinned-account failure

The check fails closed. An API error can never be reported as an empty account. `idle-resource-check.sh` remains as a compatibility alias.

Resource API requests can have small request charges. The verifier intentionally avoids Cost Explorer because Cost Explorer is charged per request and billing data lags.

## Rebuild and teardown

Both lifecycle scripts default to read-only planning:

```bash
AWS_PROFILE=personal ./rebuild-cluster.sh --plan
AWS_PROFILE=personal ./teardown-cluster.sh --plan
```

`--execute` requires an interactive `approve` immediately before each mutation. The scripts show the resource, current cost evidence or explicit uncertainty, project use, consequence, restoration path, and exact command. They refuse non-interactive mutation.

The rebuild script:

- verifies that the configured Kubernetes version is still in standard support;
- applies project, owner, environment, same-day teardown, and 24-hour expiration tags;
- creates both GPU node groups at desired size zero;
- uses encrypted node volumes;
- installs the EFS CSI driver, encrypted EFS model cache, Prometheus/Grafana, KEDA, vLLM, metrics wiring, autoscaling definition, and dashboard;
- verifies both GPU groups remain at zero.

The teardown script preserves the required order: EFS mount targets, EFS filesystem, EFS security group, then EKS. Its waits are bounded, and it ends by running the comprehensive verifier. A leftover resource or failed check returns nonzero.

## Budget alarms

The existing AWS Budget is $25/month, with email at 40% actual, 100% actual, and 100% forecasted.

Verify without storing or printing an account number:

```bash
account_id=$(aws sts get-caller-identity --profile personal --query Account --output text)
aws budgets describe-budgets --account-id "$account_id" --profile personal \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output text
```

Budget evaluation lags. The resource verifier is the immediate control.

## Nightly check

The Codex automation runs the verifier nightly at 9:00 PM America/Phoenix. It stays quiet on exit 0 and reports only resources found, incomplete scans, or authentication failures. It never tears down infrastructure.
