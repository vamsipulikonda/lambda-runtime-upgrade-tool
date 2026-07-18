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
  echo "    1) python3.8      6) python3.13     11) java8.al2"
  echo "    2) python3.9      7) nodejs16.x     12) java11"
  echo "    3) python3.10     8) nodejs18.x     13) java17"
  echo "    4) python3.11     9) nodejs20.x     14) java21"
  echo "    5) python3.12    10) nodejs22.x      c) Custom"
  echo ""
  read -p "  Select [3]: " choice

  case "${choice:-3}" in
    1) SOURCE_RUNTIME="python3.8";; 2) SOURCE_RUNTIME="python3.9";;
    3) SOURCE_RUNTIME="python3.10";; 4) SOURCE_RUNTIME="python3.11";;
    5) SOURCE_RUNTIME="python3.12";; 6) SOURCE_RUNTIME="python3.13";;
    7) SOURCE_RUNTIME="nodejs16.x";; 8) SOURCE_RUNTIME="nodejs18.x";;
    9) SOURCE_RUNTIME="nodejs20.x";; 10) SOURCE_RUNTIME="nodejs22.x";;
    11) SOURCE_RUNTIME="java8.al2";; 12) SOURCE_RUNTIME="java11";;
    13) SOURCE_RUNTIME="java17";; 14) SOURCE_RUNTIME="java21";;
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
    echo "    1) Node.js 18    2) Node.js 20    3) Node.js 22    4) Node.js 24 (latest)"
    read -p "  Select [4]: " choice
    case "${choice:-4}" in
      1) TARGET_VERSION="18"; TARGET_RUNTIME="nodejs18.x";;
      2) TARGET_VERSION="20"; TARGET_RUNTIME="nodejs20.x";;
      3) TARGET_VERSION="22"; TARGET_RUNTIME="nodejs22.x";;
      *) TARGET_VERSION="24"; TARGET_RUNTIME="nodejs24.x";;
    esac
    TRANSFORM_NAME="AWS/nodejs-version-upgrade"
  elif [[ "$SOURCE_RUNTIME" == java* ]]; then
    echo "    1) Java 11    2) Java 17    3) Java 21    4) Java 25 (latest)"
    read -p "  Select [4]: " choice
    case "${choice:-4}" in
      1) TARGET_VERSION="11"; TARGET_RUNTIME="java11";;
      2) TARGET_VERSION="17"; TARGET_RUNTIME="java17";;
      3) TARGET_VERSION="21"; TARGET_RUNTIME="java21";;
      *) TARGET_VERSION="25"; TARGET_RUNTIME="java25";;
    esac
    TRANSFORM_NAME="AWS/java-version-upgrade"
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
# Core: upgrade a single function (with layer support)
# ─────────────────────────────────────────────────────────────
upgrade_one_function() {
  local func_name="$1"
  local func_dir="$WORK_DIR/$func_name"
  local log_file="$WORK_DIR/${func_name}.log"

  mkdir -p "$func_dir/src" "$func_dir/layer"

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

    # ─── Layer handling ───
    local has_layers=false
    local layer_arns=""
    local layer_names=""
    local new_layer_arns=""

    # Check if function has layers
    layer_arns=$(echo "$config" | python3 -c "
import json,sys
config=json.load(sys.stdin)
layers=config.get('Layers',[])
if layers:
    print('\n'.join(l['Arn'] for l in layers))
" 2>/dev/null)

    if [ -n "$layer_arns" ]; then
      has_layers=true
      echo "[$func_name] Found layers, downloading layer contents..."

      local layer_idx=0
      local all_layer_reqs=""

      while IFS= read -r layer_arn; do
        [ -z "$layer_arn" ] && continue
        layer_idx=$((layer_idx + 1))

        # Extract layer name and version from ARN
        local layer_name=$(echo "$layer_arn" | python3 -c "import sys; parts=sys.stdin.read().strip().split(':'); print(parts[-2])")
        local layer_version=$(echo "$layer_arn" | python3 -c "import sys; parts=sys.stdin.read().strip().split(':'); print(parts[-1])")

        echo "[$func_name]   Layer $layer_idx: $layer_name (v$layer_version)"

        # Download layer
        local layer_url=$(aws lambda get-layer-version \
          --layer-name "$layer_name" \
          --version-number "$layer_version" \
          --region "$REGION" \
          --query 'Content.Location' --output text 2>/dev/null)

        if [ -n "$layer_url" ] && [ "$layer_url" != "None" ]; then
          local layer_dir="$func_dir/layer/${layer_name}"
          mkdir -p "$layer_dir"
          curl -s -o "$func_dir/layer/${layer_name}.zip" "$layer_url"
          unzip -q -o "$func_dir/layer/${layer_name}.zip" -d "$layer_dir/"
          rm "$func_dir/layer/${layer_name}.zip"

          # Extract dependencies from layer's python/ directory
          python3 -c "
import os
layer_python='$layer_dir/python'
reqs=[]

# Check python/ and python/lib/pythonX.Y/site-packages/
search_dirs=[layer_python]
for d in os.listdir(layer_python) if os.path.isdir(layer_python) else []:
    subdir=os.path.join(layer_python,d)
    if os.path.isdir(subdir):
        search_dirs.append(subdir)
        # Check lib/pythonX.Y/site-packages
        sp=os.path.join(subdir,'site-packages')
        if os.path.isdir(sp):
            search_dirs.append(sp)

for search_dir in search_dirs:
    if not os.path.isdir(search_dir):
        continue
    for item in os.listdir(search_dir):
        if item.endswith('.dist-info'):
            mp=os.path.join(search_dir,item,'METADATA')
            if os.path.exists(mp):
                n=v=''
                for l in open(mp):
                    if l.startswith('Name: '): n=l.strip().split(': ')[1]
                    if l.startswith('Version: '): v=l.strip().split(': ')[1]
                    if n and v: break
                if n and v: reqs.append(f'{n}=={v}')

# Write layer-specific requirements
with open('$func_dir/layer/${layer_name}_requirements.txt','w') as f:
    f.write('\n'.join(sorted(set(reqs)))+'\n' if reqs else '')
print(f'      Found {len(reqs)} packages in layer')
" 2>/dev/null

        else
          echo "[$func_name]   ⚠ Could not download layer $layer_name (may be AWS-managed)"
        fi
      done <<< "$layer_arns"

      # Merge all layer requirements into one file
      cat "$func_dir"/layer/*_requirements.txt 2>/dev/null | sort -u > "$func_dir/layer_requirements.txt"
    fi

    # ─── Create SAM template ───
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

    # ─── Build combined requirements.txt ───
    # From function deployment package
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
open('$func_dir/function_requirements.txt','w').write(('\n'.join(reqs)+'\n') if reqs else '')
" 2>/dev/null

    # Combine function + layer requirements
    cat "$func_dir/function_requirements.txt" "$func_dir/layer_requirements.txt" 2>/dev/null | sort -u > "$func_dir/requirements.txt"

    if [ -s "$func_dir/requirements.txt" ]; then
      echo "[$func_name] Combined requirements.txt:"
      cat "$func_dir/requirements.txt" | sed 's/^/    /'
    fi

    # ─── Git init ───
    cd "$func_dir"
    git init -q && git add . && git commit -q -m "Initial: $func_name ($SOURCE_RUNTIME)"

    # ─── Run ATX ───
    echo "[$func_name] Running ATX transform..."
    atx custom def exec \
      -n "$TRANSFORM_NAME" \
      -p . \
      -c "python3 -c \"import compileall; compileall.compile_dir('src', quiet=1)\"" \
      -x -t \
      --configuration "additionalPlanContext=The target Python version to upgrade to is Python $TARGET_VERSION. The requirements.txt contains all dependencies including those from Lambda layers that need upgrading." \
      > "$func_dir/atx-output.log" 2>&1 || true

    # ─── Check success & redeploy ───
    if grep -q "$TARGET_RUNTIME" template.yaml 2>/dev/null; then
      echo "[$func_name] Transform succeeded!"

      # Redeploy function code
      (cd src && zip -q -r ../upgraded.zip .)
      aws lambda update-function-code \
        --function-name "$func_name" \
        --zip-file "fileb://$func_dir/upgraded.zip" \
        --region "$REGION" > /dev/null
      aws lambda wait function-updated --function-name "$func_name" --region "$REGION" 2>/dev/null || sleep 5

      # ─── Rebuild and publish layer if function had layers ───
      if [ "$has_layers" = true ] && [ -s "$func_dir/requirements.txt" ]; then
        echo "[$func_name] Rebuilding layer with upgraded dependencies..."

        local new_layer_dir="$func_dir/new_layer/python"
        mkdir -p "$new_layer_dir"

        # Install upgraded requirements into layer structure
        # Use the ATX-upgraded requirements.txt
        pip3 install \
          -r "$func_dir/requirements.txt" \
          -t "$new_layer_dir" \
          --platform manylinux2014_x86_64 \
          --only-binary=:all: \
          --python-version "${TARGET_VERSION}" \
          --quiet 2>/dev/null || \
        pip3 install \
          -r "$func_dir/requirements.txt" \
          -t "$new_layer_dir" \
          --quiet 2>/dev/null || true

        # Check if we got packages installed
        if [ "$(ls -A "$new_layer_dir" 2>/dev/null)" ]; then
          # Also copy any native libs from the original layer (libodbc.so etc.)
          for layer_dir in "$func_dir"/layer/*/; do
            [ -d "$layer_dir" ] || continue
            # Copy non-python directories (lib/, bin/, etc.)
            for dir in lib bin etc; do
              if [ -d "$layer_dir/$dir" ]; then
                cp -r "$layer_dir/$dir" "$func_dir/new_layer/"
              fi
            done
            # Copy config files (odbcinst.ini, odbc.ini, etc.)
            find "$layer_dir" -maxdepth 1 -name "*.ini" -exec cp {} "$func_dir/new_layer/" \; 2>/dev/null
            # Copy any non-python subdirectories (msodbcsql17/, etc.)
            find "$layer_dir" -maxdepth 1 -type d ! -name "python" ! -name "." -exec cp -r {} "$func_dir/new_layer/" \; 2>/dev/null
          done

          # Package new layer
          (cd "$func_dir/new_layer" && zip -q -r ../new_layer.zip .)

          # Publish new layer version
          local layer_name_base=$(echo "$layer_arns" | head -1 | python3 -c "import sys; parts=sys.stdin.read().strip().split(':'); print(parts[-2])")
          local new_layer_name="${layer_name_base}-${TARGET_RUNTIME}"

          local new_layer_response=$(aws lambda publish-layer-version \
            --layer-name "$new_layer_name" \
            --zip-file "fileb://$func_dir/new_layer.zip" \
            --compatible-runtimes "$TARGET_RUNTIME" \
            --region "$REGION" 2>/dev/null)

          local new_layer_arn=$(echo "$new_layer_response" | python3 -c "import json,sys;print(json.load(sys.stdin)['LayerVersionArn'])" 2>/dev/null)

          if [ -n "$new_layer_arn" ]; then
            echo "[$func_name] Published new layer: $new_layer_arn"
            new_layer_arns="$new_layer_arn"
          else
            echo "[$func_name] ⚠ Layer publish failed, continuing without layer update"
          fi
        else
          echo "[$func_name] ⚠ Could not install layer packages, keeping original layers"
        fi
      fi

      # Update runtime (and layer if we have a new one)
      if [ -n "$new_layer_arns" ]; then
        aws lambda update-function-configuration \
          --function-name "$func_name" \
          --runtime "$TARGET_RUNTIME" \
          --layers "$new_layer_arns" \
          --region "$REGION" > /dev/null
      else
        aws lambda update-function-configuration \
          --function-name "$func_name" --runtime "$TARGET_RUNTIME" --region "$REGION" > /dev/null
      fi

      aws lambda wait function-updated --function-name "$func_name" --region "$REGION" 2>/dev/null || sleep 5

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
