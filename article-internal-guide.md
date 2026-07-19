# Automating Lambda Runtime Upgrades with AWS Transform custom

## The Problem

Lambda runtime deprecation is a recurring operational challenge. In 2026 alone, multiple runtimes are hitting end-of-life:

| Runtime | Deprecation Date |
|---------|-----------------|
| Ruby 3.2 | March 31, 2026 |
| Node.js 20 | April 30, 2026 |
| Python 3.10 | October 31, 2026 |
| .NET 8 | November 10, 2026 |

After deprecation, AWS stops applying security patches and eventually blocks creating or updating functions on that runtime. For teams managing dozens or hundreds of Lambda functions, manually upgrading each one is time-consuming and error-prone — especially when dependencies and code patterns need updating alongside the runtime.

## The Solution

This guide walks you through an automated approach using **AWS Transform custom** (ATX) — an AI-powered service that analyzes code, upgrades dependencies, refactors deprecated patterns, and validates the result. Combined with a discovery script, you can upgrade your entire Lambda fleet from a deprecated runtime to the latest version in minutes instead of weeks.

### What We Built

An interactive bash script that:

1. **Discovers** all Lambda functions in your account on a chosen runtime
2. **Downloads** each function's code and layer contents
3. **Runs ATX** to upgrade code + dependencies + IaC configuration
4. **Rebuilds layers** with dependencies compatible with the target runtime
5. **Redeploys** the upgraded function with the new runtime and layer
6. **Validates** by invoking the function — rolls back automatically on fatal errors
7. **Reports** success/failure with inline error messages

All in **parallel** — 9 functions upgraded simultaneously in ~5 minutes.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Your machine (laptop / Cloud Desktop / CI runner)        │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  lambda-runtime-upgrade-v2.sh                        │ │
│  │                                                      │ │
│  │  1. aws lambda list-functions (discover)             │ │
│  │  2. aws lambda get-function (download code)          │ │
│  │  3. aws lambda get-layer-version (download layers)   │ │
│  │  4. atx custom def exec (transform — parallel)       │ │
│  │  5. pip install (rebuild layer for target runtime)    │ │
│  │  6. aws lambda update-function-code (redeploy)       │ │
│  │  7. aws lambda publish-layer-version (new layer)     │ │
│  │  8. aws lambda invoke (validate)                     │ │
│  └──────────────┬──────────────────────────┬────────────┘ │
│                 │                          │              │
│        ┌────────▼────────┐       ┌────────▼────────┐    │
│        │  ATX Session 1  │       │  ATX Session N  │    │
│        │  (Function A)   │  ...  │  (Function N)   │    │
│        └────────┬────────┘       └────────┬────────┘    │
│                 │                          │              │
└─────────────────┼──────────────────────────┼─────────────┘
                  │                          │
                  ▼                          ▼
         ┌──────────────┐          ┌──────────────┐
         │ ATX Managed  │          │ ATX Managed  │
         │ Service (AWS)│          │ Service (AWS)│
         │ AI reasoning │          │ AI reasoning │
         └──────────────┘          └──────────────┘
```

## Prerequisites

| Tool | How to Install |
|------|---------------|
| AWS CLI v2 | https://aws.amazon.com/cli/ |
| ATX CLI | `curl -fsSL https://app.transform.aws.dev/install \| bash` |
| Git | Pre-installed on most systems |
| Python 3.10+ | Required for layer rebuilding (pip needs modern wheel metadata) |
| AWS credentials | `aws configure` or `aws sso login` |

### IAM Permissions Required

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaDiscoveryAndUpgrade",
      "Effect": "Allow",
      "Action": [
        "lambda:ListFunctions",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:GetLayerVersion",
        "lambda:PublishLayerVersion",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:InvokeFunction",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

## Quick Start

```bash
# Get the script
git clone https://github.com/vamsipulikonda/lambda-runtime-upgrade-tool.git
cd lambda-runtime-upgrade-tool

# Run it
./lambda-runtime-upgrade-v2.sh
```

**Source**: https://github.com/vamsipulikonda/lambda-runtime-upgrade-tool/blob/main/lambda-runtime-upgrade-v2.sh

## Supported Runtimes

| Language | From | To | ATX Transformation |
|----------|------|----|--------------------|
| Python | 3.8, 3.9, 3.10, 3.11, 3.12 | 3.11, 3.12, 3.13, 3.14 | AWS/python-version-upgrade |
| Node.js | 16.x, 18.x, 20.x | 18.x, 20.x, 22.x, 24.x | AWS/nodejs-version-upgrade |
| Java | 8.al2, 11, 17 | 11, 17, 21, 25 | AWS/java-version-upgrade |

## How It Works

### Step 1: Discovery

The script scans your account and shows all runtimes with function counts:

```
► Scanning us-east-1 for Lambda runtimes...

    40 × python3.10
    23 × python3.9 (deprecated)
    21 × python3.13 (current)
     9 × python3.11
     5 × python3.8 (deprecated)
```

You choose which runtime to upgrade from and to.

### Step 2: Function Selection

It lists every function on the chosen runtime with size and layer information:

```
  Found 9 functions on python3.11:

     1) Lambda-dlq                                    0.3 KB
     2) Cognito_trigger                               0.3 KB
     3) Bedrock-lambda                                1.0 KB [1 layer]
     ...

  Options:
    a) Upgrade ALL 9 functions
    s) Select specific ones (e.g., 1,3,5)
```

You can upgrade all or pick specific functions, then choose execution mode (sequential or parallel).

### Step 3: Parallel Transform

For each selected function, the script (in parallel):

1. Downloads the function's code via `aws lambda get-function`
2. Downloads all attached layers and extracts dependency metadata
3. Creates a SAM project structure with `template.yaml`
4. Merges function + layer dependencies into a combined `requirements.txt`
5. Initializes a git repo (required by ATX)
6. Runs `atx custom def exec -n AWS/python-version-upgrade`

ATX then:
- Analyzes the code and dependencies
- Identifies what needs to change for the target version
- Upgrades deprecated patterns (e.g., `datetime.utcnow()` → `datetime.now(timezone.utc)`)
- Upgrades dependency versions (e.g., pydantic v1 → v2, moto 4 → 5)
- Removes packages that are now in stdlib (e.g., `importlib-metadata` on Python 3.10+)
- Validates by compiling all files on the target runtime
- Commits changes to a local git branch

### Step 4: Layer Rebuild & Redeploy

If the transform succeeds:
1. Packages the transformed code into a zip
2. Updates the function code (`update-function-code`)
3. If the function had layers:
   - Installs upgraded dependencies using `pip install --platform manylinux2014_x86_64`
   - Copies native libraries from original layers (libodbc.so, etc.)
   - Publishes a new layer version for the target runtime
4. Updates the runtime and layer ARN (`update-function-configuration`)

If the transform **fails**, the function is left untouched on the original runtime.

### Step 5: Validation & Rollback

After deploying, the script invokes the function with an empty payload:
- **Fatal errors** (ImportModuleError, HandlerNotFound, SyntaxError) → automatic rollback to original runtime + layers
- **Application errors** (KeyError, ValueError from empty payload) → treated as success (function loaded fine, just needs real input)
- **No error** → confirmed success

### Step 6: Report

```
════════════════════════════════════════════════════════════
  📊 UPGRADE REPORT
════════════════════════════════════════════════════════════

  Region:          us-east-1
  Upgrade:         python3.11 → python3.13
  Total:           9
  Succeeded:       8
  Failed:          1

  ✅ Successfully upgraded:
     • Lambda-dlq → python3.13
     • Cognito_trigger → python3.13
     ...

  ❌ Failed:
     • Numpy-Lambda
       → Runtime.ImportModuleError: Unable to import module 'lambda_function': ...
════════════════════════════════════════════════════════════
```

Failed functions display the actual error message inline — no need to dig through log files.

## Real-World Results

We tested this on a live AWS account:

| Metric | Result |
|--------|--------|
| Functions upgraded | 9 (python3.11 → python3.13) |
| Parallel execution time | ~5 minutes (all 9 simultaneously) |
| Success rate | 100% (9/9) |
| ATX cost | ~$0.18 per function (~$1.60 total) |
| Manual effort | Zero (fully automated) |

For comparison, manually upgrading 9 functions (research compatibility, update code, test, deploy) would take an experienced engineer 2-4 hours.

## Cost

| Component | Cost |
|-----------|------|
| ATX agent minutes | $0.035/minute |
| Typical simple function | ~$0.10-0.25 (3-7 agent minutes) |
| Complex function (dependencies) | ~$1-2 (30-60 agent minutes) |
| 10 simple functions | ~$1.50 |
| 100 simple functions | ~$15 |

No upfront cost. No infrastructure to deploy. Pay only for active agent time.

## When to Use This vs. Other Approaches

| Scenario | Recommended Approach |
|----------|---------------------|
| Simple function, no dependencies | Direct runtime swap: `aws lambda update-function-configuration --runtime python3.13` |
| Function with dependencies or complex code | **This script (ATX)** |
| 1-50 functions | **This script (parallel on your machine)** |
| 100+ functions across many repos | ATX Batch at Scale (Fargate-based) |
| IaC-managed functions (repos exist) | Run ATX directly on the repo, deploy via CI/CD |

## Limitations

- **Container image functions**: Not supported (no code zip to download)
- **AWS-managed layers**: Layers you don't own (e.g., AWS SDK layers) may not be downloadable
- **Local Python < 3.10**: Layer rebuild will fail for packages that dropped Python 3.9 support (numpy, pandas, etc.)
- **No functional tests**: ATX validates compilation but can't run your test suite — recommend post-deploy smoke testing
- **IaC not updated**: The tool updates deployed functions but not your source repo's CloudFormation/Terraform/SAM templates
- **Cross-account**: Run the script per account, or modify to assume roles
- **Functions > 250MB unzipped**: May hit local disk limits during extraction

## Safety

- **Automatic rollback**: Fatal runtime errors after upgrade trigger rollback to original runtime + layers
- **Transform failures safe**: Functions where ATX transform fails are never redeployed — left untouched
- **Non-fatal errors tolerated**: Application errors from empty test payloads don't trigger rollback
- **Code preserved**: All original code saved in work directory with full git history
- **Error reporting**: Failed functions show actual error messages in the final report
- **Layer ARNs saved**: Original layer configurations stored for manual rollback if needed

**Recommendation**: Always run against a non-production account first to validate the approach works for your function patterns.

## Post-Upgrade Validation

After the script completes, verify your functions work:

```bash
# Invoke a function to confirm it works on the new runtime
aws lambda invoke \
  --function-name <function-name> \
  --payload '{}' \
  --region us-east-1 \
  response.json

cat response.json
```

For production functions, consider:
- Canary deployments (shift 10% traffic, monitor, then 100%)
- Lambda versions + aliases for instant rollback
- CloudWatch alarms on error rate

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

Original layer ARNs are saved at:
```
lambda-upgrades-YYYYMMDD_HHMMSS/<function-name>/original_layer_arns.txt
```

## Scaling Beyond 50 Functions

For large fleets (100+ functions), consider the **ATX Batch at Scale** solution which uses AWS Batch + Fargate to run 128 concurrent ATX sessions:

- Blog: [Building a scalable code modernization solution with AWS Transform custom](https://aws.amazon.com/blogs/devops/building-scalable-code-modernization-aws-transform/)
- Repo: [aws-samples/aws-transform-custom-samples/scaled-execution-containers](https://github.com/aws-samples/aws-transform-custom-samples/tree/main/scaled-execution-containers)
- Workshop: [Automating Lambda Runtime Upgrades with AWS Transform custom](https://catalog.us-east-1.prod.workshops.aws/workshops/48c851ba-058)

## Resources

- [Script source code](https://github.com/vamsipulikonda/lambda-runtime-upgrade-tool/blob/main/lambda-runtime-upgrade-v2.sh)
- [AWS Transform custom Documentation](https://docs.aws.amazon.com/transform/)
- [Lambda Runtime Deprecation Policy](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
- [ATX CLI Installation](https://app.transform.aws.dev/install)

## Questions?

Reach out to the AWS Transform custom team or file an issue on the [repository](https://github.com/vamsipulikonda/lambda-runtime-upgrade-tool).
