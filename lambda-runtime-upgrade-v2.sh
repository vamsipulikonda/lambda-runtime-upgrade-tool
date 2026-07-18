#!/bin/bash
# ============================================================
# 🚀 Lambda Runtime Upgrade Tool v2 (powered by AWS Transform custom)
# ============================================================
# Features:
#   - Interactive runtime & region selection
#   - Discovers all Lambda functions on chosen runtime
#   - Parallel execution (multiple ATX sessions at once)
#   - Automatic redeploy after transform
#
# Prerequisites: AWS CLI, ATX CLI, Python 3, git
#
# Usage: ./lambda-runtime-upgrade-v2.sh
# ============================================================

set -uo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

print_header() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  🚀 Lambda Runtime Upgrade Tool v2${NC}"
  echo -e "${BOLD}     Powered by AWS Transform custom (Parallel Mode)${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_step() { echo -e "${CYAN}► $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_divider() { echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"; }

# ─────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────
check_prerequisites() {
  print_step "Checking prerequisites..."
  local missing=0

  for cmd in aws atx git python3; do
    if command -v $cmd &> /dev/null; then
      echo -e "  ${GREEN}✓${NC} $cmd found"
    else
      print_error "$cmd not found"
      missing=1
    fi
  done

  if aws sts get-caller-identity &> /dev/null; then
    local account=$(aws sts get-caller-identity --query Account --output text)
    echo -e "  ${GREEN}✓${NC} AWS Account: $account"
  else
    print_error "AWS credentials not configured"
    missing=1
  fi

  [ $missing -eq 1 ] && exit 1
  echo ""
  print_success "All prerequisites met!"
}

# ─────────────────────────────────────────────────────────────
# Region selection
# ─────────────────────────────────────────────────────────────
select_region() {
  echo ""
  print_step "Select AWS Region"
  echo ""
  echo "    1) us-east-1      5) eu-west-1      8) ap-southeast-1"
  echo "    2) us-east-2      6) eu-central-1   9) ap-northeast-1"
  echo "    3) us-west-1      7) ap-south-1     c) Custom"
  echo "    4) us-west-2"
  echo ""
  read -p "  Select [1]: " choice

  case "${choice:-1}" in
    1) REGION="us-east-1";; 2) REGION="us-east-2";; 3) REGION="us-west-1";;
    4) REGION="us-west-2";; 5) REGION="eu-west-1";; 6) REGION="eu-central-1";;
    7) REGION="ap-south-1";; 8) REGION="ap-southeast-1";; 9) REGION="ap-northeast-1";;
    c|C) read -p "  Enter region: " REGION;;
    *) REGION="us-east-1";;
  esac
  echo -e "  → ${BOLD}$REGION${NC}"
}

# ─────────────────────────────────────────────────────────────
# Runtime discovery & selection
# ─────────────────────────────────────────────────────────────
select_source_runtime() {
  echo ""
  print_step "Scanning $REGION for Lambda runtimes..."
  echo ""

  # Show what's in the account
  aws lambda list-functions --region "$REGION" \
    --query "Functions[].Runtime" --output text | tr '\t' '\n' | sort | uniq -c | sort -rn | \
  while read count runtime; do
    if [[ "$runtime" == *"3.8"* ]] || [[ "$runtime" == *"3.9"* ]] || [[ "$runtime" == *"16"* ]]; then
      echo -e "    ${RED}$count × $runtime (deprecated)${NC}"
    elif [[ "$runtime" == *"3.10"* ]] || [[ "$runtime" == *"3.11"* ]] || [[ "$runtime" == *"18"* ]]; then
      echo -e "    ${YELLOW}$count × $runtime${NC}"
    else
      echo -e "    ${GREEN}$count × $runtime (current)${NC}"
    fi
  done

  echo ""
  echo "  Upgrade FROM which runtime?"
  echo "    1) python3.8     5) python3.12    8) nodejs20.x"
  echo "    2) python3.9     6) python3.13    c) Custom"
  echo "    3) python3.10    7) nodejs16.x"
  echo "    4) python3.11    8) nodejs18.x"
  echo ""
  read -p "  Select [3]: " choice

  case "${choice:-3}" in
    1) SOURCE_RUNTIME="python3.8";; 2) SOURCE_RUNTIME="python3.9";;
    3) SOURCE_RUNTIME="python3.10";; 4) SOURCE_RUNTIME="python3.11";;
    5) SOURCE_RUNTIME="python3.12";; 6) SOURCE_RUNTIME="python3.13";;
    7) SOURCE_RUNTIME="nodejs16.x";; 8) SOURCE_RUNTIME="nodejs18.x";;
    9) SOURCE_RUNTIME="nodejs20.x";;
    c|C) read -p "  Enter runtime: " SOURCE_RUNTIME;;
    *) SOURCE_RUNTIME="python3.10";;
  esac
  echo -e "  → ${BOLD}$SOURCE_RUNTIME${NC}"
}

select_target_version() {
  echo ""
  print_step "Upgrade TO which version?"
  echo ""

  if [[ "$SOURCE_RUNTIME" == python* ]]; then
    echo "    1) Python 3.11    2) Python 3.12    3) Python 3.13    4) Python 3.14 (latest)"
    read -p "  Select [4]: " choice
    case "${choice:-4}" in
      1) TARGET_VERSION="3.11"; TARGET_RUNTIME="python3.11";;
      2) TARGET_VERSION="3.12"; TARGET_RUNTIME="python3.12";;
      3) TARGET_VERSION="3.13"; TARGET_RUNTIME="python3.13";;
      *) TARGET_VERSION="3.14"; TARGET_RUNTIME="python3.14";;
    esac
    TRANSFORM_NAME="AWS/python-version-upgrade"
  elif [[ "$SOURCE_RUNTIME" == nodejs* ]]; then
    echo "    1) Node.js 18    2) Node.js 20    3) Node.js 22 (latest)"
    read -p "  Select [3]: " choice
    case "${choice:-3}" in
      1) TARGET_VERSION="18"; TARGET_RUNTIME="nodejs18.x";;
      2) TARGET_VERSION="20"; TARGET_RUNTIME="nodejs20.x";;
      *) TARGET_VERSION="22"; TARGET_RUNTIME="nodejs22.x";;
    esac
    TRANSFORM_NAME="AWS/nodejs-version-upgrade"
  fi

  echo -e "  → Upgrade: ${RED}$SOURCE_RUNTIME${NC} → ${GREEN}$TARGET_RUNTIME${NC}"
}

# ─────────────────────────────────────────────────────────────
# Function discovery & selection
# ─────────────────────────────────────────────────────────────
discover_and_select_functions() {
  echo ""
  print_step "Discovering $SOURCE_RUNTIME functions in $REGION..."
  echo ""

  # Fetch functions with details
  FUNCTIONS_JSON=$(aws lambda list-functions --region "$REGION" \
    --query "Functions[?Runtime=='$SOURCE_RUNTIME'].{Name:FunctionName,Size:CodeSize,Layers:Layers}" \
    --output json)

  FUNCTION_COUNT=$(echo "$FUNCTIONS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [ "$FUNCTION_COUNT" -eq 0 ]; then
    print_warning "No functions found on $SOURCE_RUNTIME in $REGION"
    exit 0
  fi

  echo -e "  Found ${BOLD}$FUNCTION_COUNT${NC} functions on $SOURCE_RUNTIME:"
  echo ""

  # Display table
  echo "$FUNCTIONS_JSON" | python3 -c "
import json, sys
functions = json.load(sys.stdin)
for i, fn in enumerate(functions, 1):
    name = fn['Name']
    size_kb = fn['Size'] / 1024
    layers = len(fn['Layers']) if fn['Layers'] else 0
    layer_note = f' [{layers} layer{\"s\" if layers>1 else \"\"}]' if layers else ''
    print(f'    {i:2d}) {name:<45s} {size_kb:>6.1f} KB{layer_note}')
"

  echo ""
  echo "  Options:"
  echo "    a) Upgrade ALL $FUNCTION_COUNT functions"
  echo "    s) Select specific ones (e.g., 1,3,5)"
  echo "    q) Quit"
  echo ""
  read -p "  Choose [a]: " select_choice

  case "${select_choice:-a}" in
    a|A)
      SELECTED_FUNCTIONS=$(echo "$FUNCTIONS_JSON" | python3 -c "
import json,sys
for fn in json.load(sys.stdin): print(fn['Name'])")
      ;;
    s|S)
      read -p "  Enter numbers (e.g., 1,3,5): " nums
      SELECTED_FUNCTIONS=$(echo "$FUNCTIONS_JSON" | python3 -c "
import json,sys
fns=json.load(sys.stdin)
for i in [int(x.strip())-1 for x in '$nums'.split(',')]:
    if 0<=i<len(fns): print(fns[i]['Name'])")
      ;;
    q|Q) echo "  Bye!"; exit 0;;
    *) SELECTED_FUNCTIONS=$(echo "$FUNCTIONS_JSON" | python3 -c "
import json,sys
for fn in json.load(sys.stdin): print(fn['Name'])");;
  esac

  SELECTED_COUNT=$(echo "$SELECTED_FUNCTIONS" | wc -l | tr -d ' ')
  echo ""
  echo -e "  Selected: ${BOLD}$SELECTED_COUNT${NC} functions"
}

# ─────────────────────────────────────────────────────────────
# Parallel execution settings
# ─────────────────────────────────────────────────────────────
select_parallelism() {
  echo ""
  print_step "Execution mode"
  echo ""
  echo "    1) Sequential (one at a time — safe, slower)"
  echo "    2) Parallel - 3 at a time"
  echo "    3) Parallel - 5 at a time"
  echo "    4) Parallel - ALL at once (fastest)"
  echo ""
  read -p "  Select [4]: " par_choice

  case "${par_choice:-4}" in
    1) MAX_PARALLEL=1;;
    2) MAX_PARALLEL=3;;
    3) MAX_PARALLEL=5;;
    4) MAX_PARALLEL=999;;
    *) MAX_PARALLEL=999;;
  esac

  if [ $MAX_PARALLEL -eq 1 ]; then
    echo -e "  → Sequential mode"
  elif [ $MAX_PARALLEL -eq 999 ]; then
    echo -e "  → ${BOLD}All $SELECTED_COUNT in parallel${NC} (fastest)"
  else
    echo -e "  → ${BOLD}$MAX_PARALLEL at a time${NC}"
  fi
}

# ─────────────────────────────────────────────────────────────
# Confirmation
# ─────────────────────────────────────────────────────────────
confirm() {
  echo ""
  print_divider
  echo ""
  echo -e "  ${BOLD}UPGRADE PLAN:${NC}"
  echo -e "    Region:      $REGION"
  echo -e "    From:        ${RED}$SOURCE_RUNTIME${NC}"
  echo -e "    To:          ${GREEN}$TARGET_RUNTIME${NC}"
  echo -e "    Functions:   $SELECTED_COUNT"
  echo -e "    Mode:        $([ $MAX_PARALLEL -eq 1 ] && echo 'Sequential' || echo "Parallel (max $MAX_PARALLEL)")"
  echo -e "    Transform:   $TRANSFORM_NAME"
  echo ""
  print_warning "This will modify Lambda functions in your account."
  echo ""
  read -p "  Proceed? (y/n) [y]: " yn
  [[ "${yn:-y}" != "y" && "${yn:-y}" != "Y" ]] && echo "  Aborted." && exit 0
}

# ─────────────────────────────────────────────────────────────
# Core: upgrade a single function
# ─────────────────────────────────────────────────────────────
upgrade_one_function() {
  local func_name="$1"
  local func_dir="$WORK_DIR/$func_name"
  local log_file="$WORK_DIR/${func_name}.log"

  mkdir -p "$func_dir/src"

  {
    echo "[$func_name] Downloading code..."
    local code_url=$(aws lambda get-function \
      --function-name "$func_name" --region "$REGION" \
      --query 'Code.Location' --output text)
    curl -s -o "$func_dir/function.zip" "$code_url"
    unzip -q -o "$func_dir/function.zip" -d "$func_dir/src/"
    rm "$func_dir/function.zip"

    # Get config
    local config=$(aws lambda get-function-configuration \
      --function-name "$func_name" --region "$REGION" 2>/dev/null)
    local handler=$(echo "$config" | python3 -c "import json,sys;print(json.load(sys.stdin)['Handler'])")
    local timeout=$(echo "$config" | python3 -c "import json,sys;print(json.load(sys.stdin)['Timeout'])")
    local memory=$(echo "$config" | python3 -c "import json,sys;print(json.load(sys.stdin)['MemorySize'])")

    # Create SAM template
    cat > "$func_dir/template.yaml" << EOF
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31
Resources:
  Function:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: src/
      Handler: $handler
      Runtime: $SOURCE_RUNTIME
      Timeout: $timeout
      MemorySize: $memory
EOF

    # Extract bundled dependencies
    python3 -c "
import os
src='$func_dir/src'; reqs=[]
for item in os.listdir(src):
    if item.endswith('.dist-info'):
        mp=os.path.join(src,item,'METADATA')
        if os.path.exists(mp):
            n=v=''
            for l in open(mp):
                if l.startswith('Name: '): n=l.strip().split(': ')[1]
                if l.startswith('Version: '): v=l.strip().split(': ')[1]
                if n and v: break
            if n and v: reqs.append(f'{n}=={v}')
open('$func_dir/requirements.txt','w').write(('\n'.join(reqs)+'\n') if reqs else '')
" 2>/dev/null

    # Git init
    cd "$func_dir"
    git init -q && git add . && git commit -q -m "Initial: $func_name ($SOURCE_RUNTIME)"

    # Run ATX
    echo "[$func_name] Running ATX transform..."
    atx custom def exec \
      -n "$TRANSFORM_NAME" \
      -p . \
      -c "python3 -c \"import compileall; compileall.compile_dir('src', quiet=1)\"" \
      -x -t \
      --configuration "additionalPlanContext=The target Python version to upgrade to is Python $TARGET_VERSION" \
      > "$func_dir/atx-output.log" 2>&1 || true

    # Check & redeploy
    if grep -q "$TARGET_RUNTIME" template.yaml 2>/dev/null; then
      (cd src && zip -q -r ../upgraded.zip .)
      aws lambda update-function-code \
        --function-name "$func_name" \
        --zip-file "fileb://$func_dir/upgraded.zip" \
        --region "$REGION" > /dev/null
      aws lambda wait function-updated --function-name "$func_name" --region "$REGION" 2>/dev/null || sleep 5
      aws lambda update-function-configuration \
        --function-name "$func_name" --runtime "$TARGET_RUNTIME" --region "$REGION" > /dev/null
      echo "[$func_name] ✅ SUCCESS → $TARGET_RUNTIME"
      echo "$func_name" >> "$WORK_DIR/succeeded.txt"
    else
      echo "[$func_name] ❌ FAILED"
      echo "$func_name" >> "$WORK_DIR/failed.txt"
    fi
  } > "$log_file" 2>&1
}

# ─────────────────────────────────────────────────────────────
# Main execution with parallel job control
# ─────────────────────────────────────────────────────────────
run_upgrades() {
  WORK_DIR="$(pwd)/lambda-upgrades-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$WORK_DIR"
  touch "$WORK_DIR/succeeded.txt" "$WORK_DIR/failed.txt"

  echo ""
  print_divider
  echo ""
  echo -e "  ${BOLD}Starting upgrades...${NC}"
  echo -e "  Work directory: $WORK_DIR"
  echo ""

  local running=0
  local total=0
  local pids=()
  local names=()

  while IFS= read -r func_name; do
    [ -z "$func_name" ] && continue
    total=$((total + 1))

    echo -e "  🚀 Launching: ${BOLD}$func_name${NC}"

    upgrade_one_function "$func_name" &
    pids+=($!)
    names+=("$func_name")
    running=$((running + 1))

    # Throttle if needed
    if [ $running -ge $MAX_PARALLEL ] && [ $MAX_PARALLEL -ne 999 ]; then
      # Wait for one to finish before starting next
      wait -n 2>/dev/null || wait ${pids[0]}
      running=$((running - 1))
    fi
  done <<< "$SELECTED_FUNCTIONS"

  # Wait for all remaining
  echo ""
  echo -e "  ⏳ Waiting for all $total transforms to complete..."
  echo -e "     (typically 3-7 minutes per function, running in parallel)"
  echo ""

  # Progress monitor
  while true; do
    local done_count=$(( $(wc -l < "$WORK_DIR/succeeded.txt") + $(wc -l < "$WORK_DIR/failed.txt") ))
    echo -ne "\r  Progress: $done_count / $total complete"

    if [ "$done_count" -ge "$total" ]; then
      echo ""
      break
    fi

    # Check if any background jobs are still running
    local still_running=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still_running=$((still_running + 1))
      fi
    done

    if [ $still_running -eq 0 ]; then
      echo ""
      break
    fi

    sleep 10
  done
}

# ─────────────────────────────────────────────────────────────
# Final report
# ─────────────────────────────────────────────────────────────
print_report() {
  local succeeded=$(wc -l < "$WORK_DIR/succeeded.txt" | tr -d ' ')
  local failed=$(wc -l < "$WORK_DIR/failed.txt" | tr -d ' ')
  local total=$((succeeded + failed))

  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  📊 UPGRADE REPORT${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Region:          $REGION"
  echo -e "  Upgrade:         $SOURCE_RUNTIME → $TARGET_RUNTIME"
  echo -e "  Total:           $total"
  echo -e "  Succeeded:       ${GREEN}$succeeded${NC}"
  echo -e "  Failed:          ${RED}$failed${NC}"
  echo ""

  if [ "$succeeded" -gt 0 ]; then
    echo -e "  ${GREEN}✅ Successfully upgraded:${NC}"
    while IFS= read -r fn; do
      echo -e "     • $fn → $TARGET_RUNTIME"
    done < "$WORK_DIR/succeeded.txt"
    echo ""
  fi

  if [ "$failed" -gt 0 ]; then
    echo -e "  ${RED}❌ Failed (check logs):${NC}"
    while IFS= read -r fn; do
      echo -e "     • $fn → $WORK_DIR/$fn.log"
    done < "$WORK_DIR/failed.txt"
    echo ""
  fi

  # Verify in AWS
  echo -e "  ${BOLD}Verification:${NC}"
  aws lambda list-functions --region "$REGION" \
    --query "Functions[?Runtime=='$TARGET_RUNTIME'].FunctionName" \
    --output text | tr '\t' '\n' | while read fn; do
    # Only show our upgraded functions
    if grep -q "$fn" "$WORK_DIR/succeeded.txt" 2>/dev/null; then
      echo -e "     ${GREEN}✓${NC} $fn = $TARGET_RUNTIME"
    fi
  done

  echo ""
  echo -e "  Logs: $WORK_DIR/"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
main() {
  print_header
  check_prerequisites
  print_divider
  select_region
  select_source_runtime
  select_target_version
  discover_and_select_functions
  select_parallelism
  confirm
  run_upgrades
  print_report
}

main
