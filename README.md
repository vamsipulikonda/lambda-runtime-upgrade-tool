# Lambda Runtime Upgrade Tool

Automated Lambda runtime upgrades using AWS Transform custom. Discovers deprecated functions, transforms code + dependencies, and redeploys — all from a single interactive script.

## What It Does

1. **Discovers** all Lambda functions on a chosen runtime (e.g., python3.8, python3.10)
2. **Downloads** function code from AWS
3. **Transforms** using AWS Transform custom (upgrades code, dependencies, IaC)
4. **Redeploys** the upgraded function with the new runtime
5. **Reports** success/failure with logs

Supports **parallel execution** — upgrade 10, 50, or 100+ functions simultaneously.

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI v2 | https://aws.amazon.com/cli/ |
| ATX CLI | `curl -fsSL https://app.transform.aws.dev/install \| bash` |
| Git | Pre-installed on most systems |
| Python 3 | Pre-installed on most systems |

### Installing ATX

```bash
# One-line install
curl -fsSL https://app.transform.aws.dev/install | bash

# Verify
atx --version
```

ATX requires authenticated AWS credentials (same as AWS CLI). No additional signup or enablement needed — if you have an AWS account, you can use ATX. Billed at $0.035 per agent-minute (pay-per-use, no upfront cost).

## IAM Permissions

Attach `iam-policy.json` to the IAM user/role running the script. Minimum permissions:
- `lambda:ListFunctions` — discover functions
- `lambda:GetFunction` — download code
- `lambda:GetFunctionConfiguration` — read handler, timeout, memory
- `lambda:UpdateFunctionCode` — upload transformed code
- `lambda:UpdateFunctionConfiguration` — change runtime setting
- `lambda:PublishVersion` — snapshot before upgrade (rollback safety)
- `sts:GetCallerIdentity` — verify credentials

## Usage

```bash
chmod +x lambda-runtime-upgrade-v2.sh
./lambda-runtime-upgrade-v2.sh
```

The script will interactively prompt you for:
- AWS Region
- Source runtime (what to upgrade FROM)
- Target version (what to upgrade TO)
- Which functions to upgrade (all or specific ones)
- Execution mode (sequential or parallel)

## Cost

- **ATX agent minutes**: ~$0.035/min × ~3-7 min per function
- **Typical cost**: ~$0.10 - $0.25 per simple function, ~$1-2 per complex function
- Functions that fail transform are NOT redeployed (no wasted cost)

## What ATX Validates Before Redeploying

- ✅ Code compiles on target Python version (no syntax errors)
- ✅ Dependencies are compatible with target version
- ✅ SAM/CloudFormation template updated to new runtime

## What It Does NOT Validate

- ❌ Runtime behavior with real event payloads
- ❌ Integration with downstream services
- ❌ Performance characteristics

**Recommendation**: For production functions, test with a canary deployment after upgrade.

## Safety Features

- Functions where ATX transform **fails** are left untouched (not redeployed)
- All original code is preserved in the work directory
- Git history maintained — can diff before/after
- Logs saved per function for review

## Output Structure

After running, you'll find:
```
lambda-upgrades-YYYYMMDD_HHMMSS/
├── succeeded.txt              # List of upgraded functions
├── failed.txt                 # List of failed functions
├── FunctionName.log           # Per-function execution log
└── FunctionName/              # Per-function work directory
    ├── src/                   # Extracted + transformed code
    ├── template.yaml          # SAM template (shows new runtime)
    ├── requirements.txt       # Detected dependencies
    ├── atx-output.log         # ATX session log
    └── .git/                  # Full git history of changes
```

## Supported Runtimes

| From | To | Transform |
|------|-----|-----------|
| python3.8 | python3.11/3.12/3.13 | AWS/python-version-upgrade |
| python3.9 | python3.11/3.12/3.13 | AWS/python-version-upgrade |
| python3.10 | python3.12/3.13 | AWS/python-version-upgrade |
| python3.11 | python3.12/3.13 | AWS/python-version-upgrade |
| nodejs16.x | nodejs18.x/20.x/22.x | AWS/nodejs-version-upgrade |
| nodejs18.x | nodejs20.x/22.x | AWS/nodejs-version-upgrade |

## Limitations

- **Lambda Layers**: Functions with runtime-specific layers (e.g., `AWSSDKPandas-Python311`) need manual layer ARN update after upgrade
- **Container image functions**: Not supported (no code zip to download)
- **Functions > 50MB**: May hit `/tmp` space limits during extraction
- **No tests available**: ATX can still upgrade but validation is weaker
- **Cross-account**: Run the script separately per account (or assume roles)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| ATX times out | Check `$WORK_DIR/FunctionName/atx-output.log` |
| Function fails after upgrade | Rollback: `aws lambda update-function-configuration --function-name X --runtime python3.11` |
| Script can't download code | Check IAM permissions (`lambda:GetFunction`) |
| "No functions found" | Verify region and runtime spelling |

## Related Resources

- [AWS Transform custom Documentation](https://docs.aws.amazon.com/transform/)
- [Lambda Runtime Deprecation Policy](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
- [ATX Batch at Scale (for 100+ functions)](https://github.com/aws-samples/aws-transform-custom-samples/tree/main/scaled-execution-containers)
