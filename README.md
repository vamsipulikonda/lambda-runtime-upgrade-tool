# Lambda Runtime Upgrade Tool

Automated Lambda runtime upgrades using AWS Transform custom. Discovers deprecated functions, transforms code + dependencies, rebuilds layers, validates deployments, and rolls back on failure — all from a single interactive script.

## What It Does

1. **Discovers** all Lambda functions on a chosen runtime (e.g., python3.8, nodejs16.x, java11)
2. **Downloads** function code and layer contents from AWS
3. **Transforms** using AWS Transform custom (upgrades code, dependencies, IaC)
4. **Rebuilds layers** with dependencies compatible with the target runtime
5. **Redeploys** the upgraded function with the new runtime and layer
6. **Validates** by invoking the function — rolls back automatically on fatal errors
7. **Reports** success/failure with error messages inline

Supports **parallel execution** — upgrade 10, 50, or 100+ functions simultaneously.

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI v2 | https://aws.amazon.com/cli/ |
| ATX CLI | `curl -fsSL https://app.transform.aws.dev/install \| bash` |
| Git | Pre-installed on most systems |
| Python 3.10+ | Required for layer rebuilding (pip needs to resolve modern wheel metadata) |

### Installing ATX

```bash
# One-line install
curl -fsSL https://app.transform.aws.dev/install | bash

# Verify
atx --version
```

ATX requires authenticated AWS credentials (same as AWS CLI). No additional signup or enablement needed — if you have an AWS account, you can use ATX. Billed at $0.035 per agent-minute (pay-per-use, no upfront cost).

### Python version requirement

The script uses `pip3` to rebuild Lambda layers for the target runtime. If your local Python is older than 3.10, pip cannot resolve wheels for packages like numpy or pandas that have dropped Python 3.9 support. Verify with:

```bash
python3 --version  # Must be 3.10+
pip3 --version
```

If using macOS with Homebrew, ensure `/opt/homebrew/bin` is before `/usr/bin` in your PATH.

## IAM Permissions

Attach `iam-policy.json` to the IAM user/role running the script. Required permissions:

- `lambda:ListFunctions` — discover functions
- `lambda:GetFunction` — download function code
- `lambda:GetFunctionConfiguration` — read handler, timeout, memory, layers
- `lambda:GetLayerVersion` — download layer contents
- `lambda:PublishLayerVersion` — publish rebuilt layer for target runtime
- `lambda:UpdateFunctionCode` — upload transformed code
- `lambda:UpdateFunctionConfiguration` — change runtime and layer ARNs
- `lambda:InvokeFunction` — post-deploy validation
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

## Supported Runtimes

| Language | From | To | ATX Transformation |
|----------|------|----|--------------------|
| Python | 3.8, 3.9, 3.10, 3.11, 3.12 | 3.11, 3.12, 3.13, 3.14 | AWS/python-version-upgrade |
| Node.js | 16.x, 18.x, 20.x | 18.x, 20.x, 22.x, 24.x | AWS/nodejs-version-upgrade |
| Java | 8.al2, 11, 17 | 11, 17, 21, 25 | AWS/java-version-upgrade |

## Cost

- **ATX agent minutes**: ~$0.035/min × ~3-7 min per function
- **Typical cost**: ~$0.10–0.25 per simple function, ~$1–2 per complex function
- Functions that fail transform are NOT redeployed (no wasted cost)

| Scenario | Estimated Cost |
|----------|---------------|
| 10 simple functions | ~$1.50 |
| 50 functions (mixed complexity) | ~$10–25 |
| 100 simple functions | ~$15–25 |

## Safety Features

- **Automatic rollback**: If the upgraded function fails with import/syntax/handler errors, it's rolled back to the original runtime and layers
- **Non-fatal errors ignored**: Application errors from empty test payloads (e.g., `KeyError`) are not treated as failures — they mean the function loaded successfully
- **Transform failures safe**: Functions where ATX transform fails are left untouched (never redeployed)
- **Code preserved**: All original code is saved in the work directory with full git history
- **Error reporting**: Failed functions show the actual error message in the final report

## How Layer Handling Works

For functions with Lambda layers, the script:

1. Downloads each layer version and extracts package metadata
2. Merges layer + function dependencies into a combined `requirements.txt`
3. After ATX transforms the code, rebuilds the layer using `pip install --platform manylinux2014_x86_64`
4. Publishes a new layer version compatible with the target runtime
5. Updates the function to use the new layer ARN

If layer rebuild fails (e.g., packages unavailable for target platform), the script attempts unpinned versions as a fallback.

## Output Structure

After running, you'll find:
```
lambda-upgrades-YYYYMMDD_HHMMSS/
├── succeeded.txt              # List of upgraded functions
├── failed.txt                 # List of failed functions
├── failed_reasons.txt         # Error messages for each failure
├── FunctionName.log           # Per-function execution log
└── FunctionName/              # Per-function work directory
    ├── src/                   # Extracted + transformed code
    ├── layer/                 # Original layer contents
    ├── new_layer/             # Rebuilt layer for target runtime
    ├── template.yaml          # SAM template (shows new runtime)
    ├── requirements.txt       # Combined dependencies (function + layers)
    ├── upgraded.zip           # Deployed code package
    ├── new_layer.zip          # Deployed layer package
    ├── validation_response.json # Post-deploy invoke result
    ├── atx-output.log         # ATX session log
    └── .git/                  # Full git history of changes
```

## What ATX Validates Before Redeploying

- ✅ Code compiles on target runtime (no syntax errors)
- ✅ Dependencies are compatible with target version
- ✅ SAM/CloudFormation template updated to new runtime

## What It Does NOT Validate

- ❌ Runtime behavior with real event payloads
- ❌ Integration with downstream services
- ❌ Performance characteristics

**Recommendation**: For production functions, test with a canary deployment after upgrade.

## Limitations

- **Container image functions**: Not supported (no code zip to download)
- **AWS-managed layers**: Layers you don't own (e.g., AWS SDK layers) may not be downloadable
- **Local Python < 3.10**: Layer rebuild will fail for packages that dropped Python 3.9 support (numpy, pandas, etc.)
- **Functions > 250MB unzipped**: May hit disk limits during extraction
- **No functional tests**: ATX validates compilation but can't run your test suite
- **IaC not updated**: The tool updates deployed functions but not your source repo's CloudFormation/Terraform/SAM templates
- **Cross-account**: Run the script separately per account (or assume roles)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| ATX times out | Check `$WORK_DIR/FunctionName/atx-output.log` |
| Layer rebuild fails with "requires different Python" | Upgrade local Python to 3.10+ (`brew install python@3.13`) |
| Function fails after upgrade | Script auto-rolls back; check `failed_reasons.txt` for details |
| Script can't download layer | Verify `lambda:GetLayerVersion` permission; AWS-managed layers may not be accessible |
| "No functions found" | Verify region and runtime spelling |

## Rollback

The script automatically rolls back on fatal errors. For manual rollback:

```bash
# Restore original runtime
aws lambda update-function-configuration \
  --function-name <function-name> \
  --runtime python3.11 \
  --region us-east-1

# Restore original layers (ARNs saved in work directory)
aws lambda update-function-configuration \
  --function-name <function-name> \
  --layers arn:aws:lambda:us-east-1:123456789:layer:MyLayer:1 \
  --region us-east-1
```

Original layer ARNs are saved at: `$WORK_DIR/<FunctionName>/original_layer_arns.txt`

## Related Resources

- [AWS Transform custom Documentation](https://docs.aws.amazon.com/transform/)
- [Lambda Runtime Deprecation Policy](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
- [ATX Batch at Scale (for 100+ functions)](https://github.com/aws-samples/aws-transform-custom-samples/tree/main/scaled-execution-containers)
