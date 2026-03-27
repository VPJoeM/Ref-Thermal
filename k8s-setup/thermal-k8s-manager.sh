#!/usr/bin/env bash
# thermal-k8s-manager.sh - GPU Thermal Diagnostics K8s Manager (Reflection)
# Deploys thermal diagnostics as K8s Jobs across GPU nodes in parallel
# Version 1.0.0

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

THERMAL_SCRIPT="${SCRIPT_DIR}/../thermal-diagnostics-2.6.2-vp.sh"
JOB_TEMPLATE="${SCRIPT_DIR}/job-template.yaml"
NAMESPACE_YAML="${SCRIPT_DIR}/namespace.yaml"
DOCKERFILE_DIR="${SCRIPT_DIR}"
IMAGE_NAME="thermal-diagnostics"
IMAGE_TAG="2.6.2"
IMAGE_FULL="${IMAGE_NAME}:${IMAGE_TAG}"
REPORTS_DIR="${HOME}/Reports/thermal-diagnostics"

DEFAULT_SSH_USER="${SSH_USER:-vpsupport}"
DEFAULT_GPU_COUNT=8
SSHV_COMMAND="sshv"
JUMP_HOST="10.9.231.200"

EXECUTION_MODE=""
CONTROL_PLANE_IP=""
KUBECONFIG_FILE=""
KUBECONFIG_CACHE_DIR="/tmp/.thermal-k8s-kubeconfigs"
KUBECONFIG_HISTORY_FILE="/tmp/.thermal-k8s-kubeconfig-history.cache"
GDRIVE_TEAM_DRIVE="0AEnvoKAUzsPmUk9PVA"
GDRIVE_FOLDER="thermal-results"

declare -A IP_MAP_INTERNAL
declare -A IP_MAP_HOSTNAME
declare -A NODE_PUBLIC_IPS
declare -A NODE_CONNECT    # ip -> "direct" or "proxy:private_ip"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

# ─── SSH/SSHV with proxy auto-detect ─────────────────────────

check_sshv() { command -v "$SSHV_COMMAND" &>/dev/null; }

# sshv wrapper that routes through proxy if needed for a given IP
sshv_cmd() {
    local pub_ip="$1"; shift
    local method="${NODE_CONNECT[$pub_ip]:-direct}"
    if [[ "$method" == proxy:* ]]; then
        local priv_ip="${method#proxy:}"
        $SSHV_COMMAND -o ProxyCommand="$SSHV_COMMAND -W %h:%p ${DEFAULT_SSH_USER}@${JUMP_HOST}" \
            "${DEFAULT_SSH_USER}@${priv_ip}" "$@" 2>/dev/null
    else
        $SSHV_COMMAND "${DEFAULT_SSH_USER}@${pub_ip}" "$@" 2>/dev/null
    fi
}

# sshv scp wrapper with proxy support
sshv_scp_from() {
    local pub_ip="$1" remote="$2" local_path="$3"
    local method="${NODE_CONNECT[$pub_ip]:-direct}"
    if [[ "$method" == proxy:* ]]; then
        local priv_ip="${method#proxy:}"
        scp -o ProxyCommand="$SSHV_COMMAND -W %h:%p ${DEFAULT_SSH_USER}@${JUMP_HOST}" \
            -o StrictHostKeyChecking=no "${DEFAULT_SSH_USER}@${priv_ip}:${remote}" "$local_path" 2>/dev/null
    else
        $SSHV_COMMAND scp "${DEFAULT_SSH_USER}@${pub_ip}:${remote}" "$local_path" 2>/dev/null
    fi
}

sshv_scp_to() {
    local pub_ip="$1" local_path="$2" remote="$3"
    local method="${NODE_CONNECT[$pub_ip]:-direct}"
    if [[ "$method" == proxy:* ]]; then
        local priv_ip="${method#proxy:}"
        scp -o ProxyCommand="$SSHV_COMMAND -W %h:%p ${DEFAULT_SSH_USER}@${JUMP_HOST}" \
            -o StrictHostKeyChecking=no "$local_path" "${DEFAULT_SSH_USER}@${priv_ip}:${remote}" 2>/dev/null
    else
        $SSHV_COMMAND scp "$local_path" "${DEFAULT_SSH_USER}@${pub_ip}:${remote}" 2>/dev/null
    fi
}

# test connectivity to all node public IPs, auto-detect proxy needs
test_node_connectivity() {
    echo -e "\n  ${CYAN}Testing SSH connectivity...${NC}"
    for pub_ip in "${!NODE_PUBLIC_IPS[@]}"; do
        local nn="${pub_ip}"
        # find the hostname for this IP
        for k in "${!NODE_PUBLIC_IPS[@]}"; do
            [[ "${NODE_PUBLIC_IPS[$k]}" == "$pub_ip" ]] && nn="$k"
        done
        echo -ne "  ${pub_ip} (${nn}): "
        if sshv_cmd "$pub_ip" "echo ok" &>/dev/null 2>&1; then
            NODE_CONNECT["$pub_ip"]="direct"
            echo -e "${GREEN}direct OK${NC}"
        else
            echo -e "${YELLOW}direct failed${NC}"
            echo -e "  ${DIM}May require SSH via jump host (${JUMP_HOST})${NC}"
            read -p "  Enter private IP for ${pub_ip} (or 'skip'): " priv_ip </dev/tty
            if [[ "$priv_ip" == "skip" ]]; then
                echo -e "  ${RED}Skipping ${pub_ip}${NC}"
                continue
            fi
            echo -ne "  Testing via proxy (${priv_ip}): "
            if $SSHV_COMMAND -o ProxyCommand="$SSHV_COMMAND -W %h:%p ${DEFAULT_SSH_USER}@${JUMP_HOST}" \
                "${DEFAULT_SSH_USER}@${priv_ip}" "echo ok" &>/dev/null 2>&1; then
                NODE_CONNECT["$pub_ip"]="proxy:${priv_ip}"
                echo -e "${GREEN}OK via ${JUMP_HOST} → ${priv_ip}${NC}"
            else
                echo -e "${RED}FAILED${NC}"
                log_error "Cannot reach ${pub_ip} directly or via proxy"
                return 1
            fi
        fi
    done
}

# ─── Execution Mode ──────────────────────────────────────────

detect_execution_mode() {
    [[ -n "$EXECUTION_MODE" ]] && return 0
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        EXECUTION_MODE="local"; log_success "Running locally on cluster node"; return 0
    fi
    if command -v kubectl &>/dev/null && sudo kubectl cluster-info &>/dev/null 2>&1; then
        EXECUTION_MODE="local"; log_success "Running locally (kubectl via sudo)"; return 0
    fi
    echo -e "\n${CYAN}${BOLD}Connection Method${NC}"
    echo -e "  ${GREEN}1)${NC} ${BOLD}Via sshv${NC} ${DIM}(route kubectl to a control node)${NC}"
    echo -e "  ${GREEN}2)${NC} ${BOLD}Kubeconfig file${NC} ${DIM}(kubectl runs locally)${NC}"
    echo ""
    read -p "  Choice [1-2]: " mc
    case "$mc" in
        1) EXECUTION_MODE="remote"; check_sshv || { log_error "sshv not found"; exit 1; } ;;
        2) EXECUTION_MODE="kubeconfig"; prompt_for_kubeconfig || exit 1 ;;
        *) log_error "Invalid"; exit 1 ;;
    esac
}

prompt_for_kubeconfig() {
    echo -e "\n${CYAN}${BOLD}Kubeconfig Setup${NC}"
    echo -e "  ${GREEN}1)${NC} Provide file path"
    echo -e "  ${GREEN}2)${NC} Paste content"
    read -p "  Choice [1-2]: " kc
    case "$kc" in
        1) read -e -p "  Path: " kf; kf="${kf/#\~/$HOME}"
           [[ ! -f "$kf" ]] && { log_error "Not found: $kf"; return 1; }
           KUBECONFIG_FILE="$kf" ;;
        2) mkdir -p "$KUBECONFIG_CACHE_DIR" 2>/dev/null; chmod 700 "$KUBECONFIG_CACHE_DIR"
           KUBECONFIG_FILE="${KUBECONFIG_CACHE_DIR}/kubeconfig-$(date +%s)"
           echo -e "  ${DIM}Paste kubeconfig, Ctrl+D when done:${NC}"; cat > "$KUBECONFIG_FILE"; chmod 600 "$KUBECONFIG_FILE" ;;
        *) return 1 ;;
    esac
    KUBECONFIG="$KUBECONFIG_FILE" kubectl cluster-info &>/dev/null 2>&1 || { log_error "Cannot connect"; return 1; }
    log_success "Kubeconfig valid"
}

kubectl_exec() {
    case "$EXECUTION_MODE" in
        local) if [[ "$EUID" -ne 0 ]]; then sudo kubectl "$@"; else kubectl "$@"; fi ;;
        kubeconfig) KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@" ;;
        remote)
            local cmd="sudo kubectl"
            for arg in "$@"; do cmd="$cmd $(printf '%q' "$arg")"; done
            sshv_cmd "$CONTROL_PLANE_IP" "$cmd" ;;
    esac
}

remote_kubectl() { kubectl_exec $@; }

check_kubectl() {
    case "$EXECUTION_MODE" in
        local) kubectl cluster-info &>/dev/null 2>&1 || sudo kubectl cluster-info &>/dev/null 2>&1 || { log_error "kubectl can't reach cluster"; return 1; } ;;
        kubeconfig) KUBECONFIG="$KUBECONFIG_FILE" kubectl cluster-info &>/dev/null 2>&1 || { log_error "kubeconfig can't reach cluster"; return 1; } ;;
        remote) [[ -z "$CONTROL_PLANE_IP" ]] && { log_error "Control plane IP not set"; return 1; }
                sshv_cmd "$CONTROL_PLANE_IP" "sudo kubectl cluster-info" &>/dev/null 2>&1 || { log_error "Can't reach cluster on $CONTROL_PLANE_IP"; return 1; } ;;
    esac
}

# ─── Node Resolution ─────────────────────────────────────────

resolve_node_ips() {
    local pub_ip="$1"
    local iip hn
    iip=$(sshv_cmd "$pub_ip" "ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || hostname -I | awk '{print \$1}'" | tr -d '\r')
    hn=$(sshv_cmd "$pub_ip" "hostname -s" | tr -d '\r')
    [[ -n "$iip" ]] && IP_MAP_INTERNAL["$pub_ip"]="$iip"
    [[ -n "$hn" ]] && IP_MAP_HOSTNAME["$pub_ip"]="$hn"
    echo "${hn:-unknown}:${iip:-unknown}"
}

resolve_node_name() {
    local pub_ip="$1"
    [[ -n "${IP_MAP_HOSTNAME[$pub_ip]:-}" ]] && { echo "${IP_MAP_HOSTNAME[$pub_ip]}"; return; }
    local iip="${IP_MAP_INTERNAL[$pub_ip]:-$pub_ip}"
    local nn
    nn=$(kubectl_exec get nodes -o wide --no-headers 2>/dev/null | grep -w "$iip" | awk '{print $1}' | head -1)
    [[ -z "$nn" ]] && { resolve_node_ips "$pub_ip" >/dev/null; nn="${IP_MAP_HOSTNAME[$pub_ip]:-}"; }
    echo "$nn"
}

get_node_gpu_count() {
    local n="$1"
    kubectl_exec get node "$n" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null
}

get_all_gpu_nodes() {
    kubectl_exec get nodes -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

get_node_internal_ip() {
    local n="$1"
    kubectl_exec get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}

auto_detect_control_plane() {
    local ip="$1"
    [[ "$EXECUTION_MODE" != "remote" ]] && return 0
    local r
    r=$(sshv_cmd "$ip" "sudo kubectl get nodes --no-headers 2>/dev/null | head -3")
    [[ -n "$r" ]] && { CONTROL_PLANE_IP="$ip"; log_success "Control plane: $ip"; return 0; }
    return 1
}

# ─── Image Build & Distribution ──────────────────────────────

build_image() {
    echo -e "\n${CYAN}Building image on control plane (${CONTROL_PLANE_IP})...${NC}"
    [[ ! -f "$THERMAL_SCRIPT" ]] && { log_error "Script not found: $THERMAL_SCRIPT"; return 1; }
    cp "$THERMAL_SCRIPT" "${DOCKERFILE_DIR}/thermal-diagnostics-2.6.2-vp.sh" 2>/dev/null
    sshv_cmd "$CONTROL_PLANE_IP" "mkdir -p /tmp/thermal-build"
    $SSHV_COMMAND scp -o StrictHostKeyChecking=no \
        "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}/entrypoint.sh" "${DOCKERFILE_DIR}/thermal-diagnostics-2.6.2-vp.sh" \
        "${DEFAULT_SSH_USER}@${CONTROL_PLANE_IP}:/tmp/thermal-build/" 2>/dev/null
    rm -f "${DOCKERFILE_DIR}/thermal-diagnostics-2.6.2-vp.sh" 2>/dev/null
    log_info "Building (1-2 min)..."
    sshv_cmd "$CONTROL_PLANE_IP" "cd /tmp/thermal-build && sudo docker build -t '${IMAGE_FULL}' . 2>&1 | tail -5"
    [[ $? -eq 0 ]] && log_success "Image built: $IMAGE_FULL" || { log_error "Build failed"; return 1; }
}

distribute_image() {
    local nodes=("$@")
    echo -e "\n${CYAN}Distributing image to ${#nodes[@]} node(s)...${NC}"
    local failed=0
    for pub_ip in "${nodes[@]}"; do
        local hn="${IP_MAP_HOSTNAME[$pub_ip]:-$pub_ip}"
        local existing
        existing=$(sshv_cmd "$pub_ip" "sudo crictl images 2>/dev/null | grep -c '$IMAGE_NAME' || echo 0" | tr -d '\r')
        if [[ "${existing:-0}" -gt 0 ]]; then
            echo -e "  ${GREEN}✓${NC} $hn -- already present"; continue
        fi
        echo -e "  ${YELLOW}→${NC} Building on $hn..."
        cp "$THERMAL_SCRIPT" "${DOCKERFILE_DIR}/thermal-diagnostics-2.6.2-vp.sh" 2>/dev/null
        sshv_cmd "$pub_ip" "mkdir -p /tmp/thermal-build"
        $SSHV_COMMAND scp -o StrictHostKeyChecking=no \
            "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}/entrypoint.sh" "${DOCKERFILE_DIR}/thermal-diagnostics-2.6.2-vp.sh" \
            "${DEFAULT_SSH_USER}@${pub_ip}:/tmp/thermal-build/" 2>/dev/null
        rm -f "${DOCKERFILE_DIR}/thermal-diagnostics-2.6.2-vp.sh" 2>/dev/null
        sshv_cmd "$pub_ip" "cd /tmp/thermal-build && sudo docker build -t '${IMAGE_FULL}' . 2>&1 | tail -3 && \
             sudo docker save '${IMAGE_FULL}' | sudo ctr -n k8s.io images import - && \
             rm -rf /tmp/thermal-build"
        local v
        v=$(sshv_cmd "$pub_ip" "sudo crictl images 2>/dev/null | grep -c '$IMAGE_NAME' || echo 0" | tr -d '\r')
        [[ "${v:-0}" -gt 0 ]] && echo -e "  ${GREEN}✓${NC} $hn" || { echo -e "  ${RED}✗${NC} $hn"; failed=$((failed+1)); }
    done
    [[ $failed -gt 0 ]] && { log_warn "$failed node(s) failed"; return 1; }
    log_success "Image on all nodes"
}

# ─── Job Creation & Monitoring ────────────────────────────────

create_job_yaml() {
    local node_name="$1" run_id="$2" altitude="$3" output_mode="$4" dc_name="$5" gpu_count="$6"
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local job_name="thermal-diag-${node_name}-${ts}"
    local yaml; yaml=$(cat "$JOB_TEMPLATE")
    yaml="${yaml//__NODE_NAME__/$node_name}"; yaml="${yaml//__JOB_NAME__/$job_name}"
    yaml="${yaml//__RUN_ID__/$run_id}"; yaml="${yaml//__ALTITUDE__/$altitude}"
    yaml="${yaml//__OUTPUT_MODE__/$output_mode}"; yaml="${yaml//__DC_NAME__/$dc_name}"
    yaml="${yaml//__IMAGE__/$IMAGE_FULL}"; yaml="${yaml//__GPU_COUNT__/$gpu_count}"
    yaml="${yaml/# __EXTRA_ENV__/}"; yaml="${yaml/# __VOLUME_RESULTS__/}"
    echo "$yaml"
}

launch_jobs() {
    local node_ips=("$@")
    local run_id="run-$(date +%s | tail -c 8)"
    echo -e "\n${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║           Launching Thermal Diagnostics                    ║${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}Run ID:${NC}        $run_id"
    echo -e "  ${CYAN}Nodes:${NC}         ${#node_ips[@]}"
    echo -e "  ${CYAN}Altitude:${NC}      ${ALTITUDE:-0} ft"
    echo -e "  ${CYAN}Output:${NC}        ${OUTPUT_MODE:-local}"
    echo -e "  ${CYAN}DC Name:${NC}       ${DC_NAME:-thermal-run}"
    echo ""
    kubectl_exec apply -f "$NAMESPACE_YAML" 2>/dev/null || \
        cat "$NAMESPACE_YAML" | kubectl_exec apply -f - 2>/dev/null

    # resolve COLLECT_NODE to hostname if public IP given
    if [[ "${OUTPUT_MODE:-local}" == "node" && -n "${COLLECT_NODE:-}" && "$COLLECT_NODE" =~ ^[0-9]+\. ]]; then
        resolve_node_ips "$COLLECT_NODE" >/dev/null
        local ch="${IP_MAP_HOSTNAME[$COLLECT_NODE]:-$COLLECT_NODE}"
        log_info "Collection node: $COLLECT_NODE → $ch"
        export COLLECT_NODE="$ch"
    fi

    local job_names=() job_nodes=()
    for nn in "${node_ips[@]}"; do
        local gc; gc=$(get_node_gpu_count "$nn")
        [[ "${gc:-0}" == "0" ]] && gc=$DEFAULT_GPU_COUNT
        local jy; jy=$(create_job_yaml "$nn" "$run_id" "${ALTITUDE:-0}" "${OUTPUT_MODE:-local}" "${DC_NAME:-thermal-run}" "$gc")
        echo -e "  ${YELLOW}→${NC} Creating job on ${nn} (${gc} GPUs)..."
        if echo "$jy" | kubectl_exec apply -f - 2>/dev/null; then
            local jn; jn=$(echo "$jy" | grep "name: thermal-diag-" | head -1 | awk '{print $2}')
            job_names+=("$jn"); job_nodes+=("$nn")
            echo -e "  ${GREEN}✓${NC} $jn"
        else
            log_error "Failed on $nn"
        fi
        sleep 1
    done
    [[ ${#job_names[@]} -eq 0 ]] && { log_error "No jobs created"; return 1; }
    echo ""; log_info "Monitoring..."
    monitor_jobs "$run_id" "${job_names[@]}"
}

monitor_jobs() {
    local run_id="$1"; shift; local job_names=("$@")
    local total=${#job_names[@]} start_time; start_time=$(date +%s)
    while true; do
        local completed=0 failed=0 running=0
        for jn in "${job_names[@]}"; do
            local jj
            jj=$(kubectl_exec get job "$jn" -n thermal-diagnostics -o json 2>/dev/null)
            if [[ -z "$jj" ]]; then
                completed=$((completed+1)); continue
            fi
            local s; s=$(echo "$jj" | grep -o '"succeeded": *[0-9]*' | head -1 | grep -o '[0-9]*$')
            local f; f=$(echo "$jj" | grep -o '"failed": *[0-9]*' | head -1 | grep -o '[0-9]*$')
            if [[ "${s:-0}" -ge 1 ]]; then completed=$((completed+1))
            elif [[ "${f:-0}" -gt 0 ]]; then failed=$((failed+1))
            else running=$((running+1)); fi
        done
        local el=$(( $(date +%s) - start_time )); local m=$((el/60)) s=$((el%60))
        printf "\r  ${CYAN}Progress:${NC} %d/%d complete | %d running | %d failed | %02d:%02d elapsed" \
            "$completed" "$total" "$running" "$failed" "$m" "$s"
        if [[ $((completed+failed)) -ge $total ]]; then
            echo ""; echo ""
            [[ $failed -gt 0 ]] && log_warn "$failed job(s) failed"
            log_success "All jobs finished. $completed succeeded, $failed failed."
            echo ""; collect_and_rollup "$run_id"
            break
        fi
        sleep 10
    done
}

# ─── Results Collection ──────────────────────────────────────

# gdrive mode: collect on first node, create rollup, upload from there
collect_and_upload_gdrive_from_node() {
    local run_id="$1" rname="$2"
    local collect_ip="${NODE_PUBLIC_IPS[${NODE_IPS[0]}]:-$CONTROL_PLANE_IP}"
    local rollup_dir="/root/Reports/thermal-results/${rname}"

    log_info "Collecting results on node, then uploading to Google Drive..."

    # create rollup dir on collection node
    sshv_cmd "$collect_ip" "sudo mkdir -p '${rollup_dir}'" 2>/dev/null

    # get node list
    local jnodes=""
    jnodes=$(sshv_cmd "$CONTROL_PLANE_IP" \
        "sudo kubectl get jobs -n thermal-diagnostics -l thermal-run=${run_id} -o jsonpath='{range .items[*]}{.spec.template.spec.nodeName}{\"\\n\"}{end}'" 2>/dev/null)
    [[ -z "$jnodes" ]] && jnodes=$(echo "${NODE_IPS[*]}" | tr ' ' '\n')

    local collected=0
    while read -r nn <&3; do
        [[ -z "$nn" ]] && continue
        echo -e "  ${YELLOW}→${NC} Collecting from ${nn}..."
        local pub_ip="${NODE_PUBLIC_IPS[$nn]:-$CONTROL_PLANE_IP}"

        local rzip
        rzip=$(sshv_cmd "$pub_ip" \
            "sudo bash -c 'ls -t /root/TDAS/dcgmprof-*.zip 2>/dev/null | head -1'" </dev/null | tr -d '\r')
        [[ -z "$rzip" ]] && { log_warn "No results on $nn"; continue; }

        local zb; zb=$(basename "$rzip")
        local st; st=$(echo "$zb" | sed -E 's/^dcgmprof-([^-]+)-.*/\1/')
        [[ "$st" == "$zb" ]] && st="UNKNOWN"
        local nzn="${nn}-${st}.zip"

        if [[ "$pub_ip" == "$collect_ip" ]]; then
            sshv_cmd "$collect_ip" "sudo cp '$rzip' '${rollup_dir}/${nzn}'" 2>/dev/null
        else
            # download from source node to Mac, upload to collection node
            sshv_cmd "$pub_ip" \
                "sudo bash -c 'cp \"$rzip\" /tmp/thermal-relay.zip && chmod 644 /tmp/thermal-relay.zip'" 2>/dev/null
            sshv_scp_from "$pub_ip" "/tmp/thermal-relay.zip" "/tmp/${nzn}"
            sshv_scp_to "$collect_ip" "/tmp/${nzn}" "/tmp/${nzn}"
            sshv_cmd "$collect_ip" "sudo mv '/tmp/${nzn}' '${rollup_dir}/${nzn}'" 2>/dev/null
            rm -f "/tmp/${nzn}"
            sshv_cmd "$pub_ip" "rm -f /tmp/thermal-relay.zip" 2>/dev/null
        fi

        local verify
        verify=$(sshv_cmd "$collect_ip" "sudo ls -lh '${rollup_dir}/${nzn}' 2>/dev/null" 2>/dev/null | tr -d '\r')
        if [[ -n "$verify" ]]; then
            local zs; zs=$(echo "$verify" | awk '{print $5}')
            echo -e "  ${GREEN}✓${NC} ${nzn} (${zs})"
            collected=$((collected+1))
        else
            log_warn "Failed to collect from $nn"
        fi
    done 3<<< "$jnodes"

    [[ $collected -eq 0 ]] && { log_error "No results collected"; return 1; }

    # create rollup zip on the node
    local remote_zip="/root/Reports/thermal-results/${rname}.zip"
    log_info "Creating rollup on node..."
    sshv_cmd "$collect_ip" \
        "sudo bash -c 'cd /root/Reports/thermal-results && zip -r ${rname}.zip ${rname}/ >/dev/null 2>&1 && rm -rf ${rname}/'" 2>/dev/null

    # install rclone, push SA key, upload
    local has_rc
    has_rc=$(sshv_cmd "$collect_ip" "which rclone 2>/dev/null" 2>/dev/null)
    if [[ -z "$has_rc" ]]; then
        log_info "Installing rclone..."
        sshv_cmd "$collect_ip" "curl -s https://rclone.org/install.sh | sudo bash" >/dev/null 2>&1
    fi

    local sa_file="${SCRIPT_DIR}/gdrive-sa.json"
    sshv_scp_to "$collect_ip" "$sa_file" "/tmp/.gdrive-sa.json"
    sshv_cmd "$collect_ip" "sudo mv /tmp/.gdrive-sa.json /tmp/.gdrive-sa.json.tmp && sudo cp /tmp/.gdrive-sa.json.tmp /tmp/.gdrive-sa.json && sudo rm /tmp/.gdrive-sa.json.tmp && sudo chmod 600 /tmp/.gdrive-sa.json"

    log_info "Uploading ${rname}.zip to Google Drive..."
    local upload_out
    upload_out=$(sshv_cmd "$collect_ip" \
        "sudo rclone copyto '${remote_zip}' ':drive:${GDRIVE_FOLDER}/${rname}.zip' \
            --drive-service-account-file /tmp/.gdrive-sa.json \
            --drive-team-drive '${GDRIVE_TEAM_DRIVE}' \
            --drive-scope drive -v 2>&1" 2>/dev/null)

    # cleanup
    sshv_cmd "$collect_ip" "sudo rm -f /tmp/.gdrive-sa.json" 2>/dev/null
    [[ -z "$has_rc" ]] && sshv_cmd "$collect_ip" "sudo rm -f /usr/bin/rclone /usr/local/bin/rclone" 2>/dev/null

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    if echo "$upload_out" | grep -qi "transferred\|copied"; then
        echo -e "${GREEN}${BOLD}  UPLOADED TO GOOGLE DRIVE${NC}"
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${CYAN}Drive:${NC}  ${GDRIVE_FOLDER}/${rname}.zip"
        echo -e "  ${CYAN}Node:${NC}   ${collect_ip}:${remote_zip}"
        echo -e "  ${CYAN}Nodes:${NC}  ${collected}"
    else
        echo -e "${YELLOW}${BOLD}  RESULTS SAVED (Drive upload may have failed)${NC}"
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${CYAN}Node:${NC}   ${collect_ip}:${remote_zip}"
        echo -e "  ${CYAN}Nodes:${NC}  ${collected}"
    fi
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
}

collect_and_rollup() {
    local run_id="$1"
    local rts; rts=$(date +%Y%m%d-%H%M%S)
    local rname="${DC_NAME:-thermal-run}-${rts}"

    # for gdrive mode, collect and upload entirely from the first node
    if [[ "${OUTPUT_MODE:-local}" == "gdrive" ]]; then
        collect_and_upload_gdrive_from_node "$run_id" "$rname"
        return $?
    fi

    local rdir="/tmp/${rname}"
    mkdir -p "$rdir"
    log_info "Collecting results..."

    local collected=0
    # get node names from jobs, or fall back to NODE_IPS if jobs were TTL-deleted
    local jnodes=""
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        jnodes=$(sshv_cmd "$CONTROL_PLANE_IP" \
            "sudo kubectl get jobs -n thermal-diagnostics -l thermal-run=${run_id} -o jsonpath='{range .items[*]}{.spec.template.spec.nodeName}{\"\\n\"}{end}'" 2>/dev/null)
    else
        jnodes=$(kubectl_exec get jobs -n thermal-diagnostics -l "thermal-run=${run_id}" \
            -o jsonpath='{range .items[*]}{.spec.template.spec.nodeName}{"\n"}{end}' 2>/dev/null)
    fi
    # fallback: use NODE_IPS which were set at launch time
    [[ -z "$jnodes" ]] && jnodes=$(echo "${NODE_IPS[*]}" | tr ' ' '\n')

    while read -r nn <&3; do
        [[ -z "$nn" ]] && continue
        echo -e "  ${YELLOW}→${NC} Collecting from ${nn}..."
        local pub_ip="${NODE_PUBLIC_IPS[$nn]:-}"
        # if no public IP mapped, try to find it from the node-ips we were given
        if [[ -z "$pub_ip" ]]; then
            # last resort: use control plane and hope it's the right node
            pub_ip="$CONTROL_PLANE_IP"
            log_warn "No public IP for $nn, using control plane $pub_ip"
        fi

        # find the dcgmprof zip on this node (use bash -c for glob expansion through sshv)
        local rzip
        rzip=$(sshv_cmd "$pub_ip" \
            "sudo bash -c 'ls -t /root/TDAS/dcgmprof-*.zip 2>/dev/null | head -1'" </dev/null | tr -d '\r')
        [[ -z "$rzip" ]] && { log_warn "No results on $nn"; continue; }

        # extract service tag from zip name
        local zb; zb=$(basename "$rzip")
        local st; st=$(echo "$zb" | sed -E 's/^dcgmprof-([^-]+)-.*/\1/')
        [[ "$st" == "$zb" ]] && st="UNKNOWN"
        local nzn="${nn}-${st}.zip"

        # download via sshv: stage to /tmp, scp down, cleanup
        sshv_cmd "$pub_ip" \
            "sudo bash -c 'cp \"$rzip\" /tmp/thermal-dl.zip && chmod 644 /tmp/thermal-dl.zip'" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            sshv_scp_from "$pub_ip" "/tmp/thermal-dl.zip" "${rdir}/${nzn}"
            sshv_cmd "$pub_ip" "rm -f /tmp/thermal-dl.zip" 2>/dev/null
        fi

        if [[ -f "${rdir}/${nzn}" ]]; then
            local zs; zs=$(du -h "${rdir}/${nzn}" | cut -f1)
            echo -e "  ${GREEN}✓${NC} ${nzn} (${zs})"
            collected=$((collected+1))
        else
            log_warn "Download failed from $nn"
        fi

        # cleanup on node
        sshv_cmd "$pub_ip" "sudo rm -f '$rzip'" 2>/dev/null
    done 3<<< "$jnodes"

    [[ $collected -eq 0 ]] && { log_error "No results collected"; rm -rf "$rdir"; return 1; }

    # create rollup zip
    local lzip="/tmp/${rname}.zip"
    log_info "Creating rollup: ${rname}.zip (${collected} nodes)..."
    (cd /tmp && zip -r "$lzip" "${rname}/" >/dev/null 2>&1)
    rm -rf "$rdir"

    [[ ! -f "$lzip" ]] && { log_error "Rollup zip failed"; return 1; }

    local fsz; fsz=$(du -h "$lzip" | cut -f1)
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  RESULTS READY${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Size:${NC}   ${fsz}"
    echo -e "  ${CYAN}Nodes:${NC}  ${collected}"
    echo -e "${DIM}Contents:${NC}"
    unzip -l "$lzip" 2>/dev/null | grep -E '\.zip$' | while read -r sz dt tm nm; do
        echo -e "  ${CYAN}•${NC} $nm"
    done
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"

    # deliver based on output mode (node/ftp -- gdrive handled above)
    case "${OUTPUT_MODE:-local}" in
        node)
            if [[ -n "${COLLECT_NODE:-}" ]]; then
                local cpub="${NODE_PUBLIC_IPS[$COLLECT_NODE]:-$CONTROL_PLANE_IP}"
                log_info "Uploading to ${COLLECT_NODE}..."
                sshv_cmd "$cpub" "sudo mkdir -p /root/Reports/thermal-results" 2>/dev/null
                $SSHV_COMMAND scp "$lzip" \
                    "${DEFAULT_SSH_USER}@${cpub}:/tmp/rollup-ul.zip" 2>/dev/null
                sshv_cmd "$cpub" \
                    "sudo mv /tmp/rollup-ul.zip /root/Reports/thermal-results/${rname}.zip" 2>/dev/null
                log_success "Uploaded to ${COLLECT_NODE}:/root/Reports/thermal-results/${rname}.zip"
            fi ;;
        gdrive)
            # upload to Google Drive from the control plane node via rclone
            local gdrive_node_ip="${NODE_PUBLIC_IPS[${NODE_IPS[0]}]:-$CONTROL_PLANE_IP}"
            log_info "Uploading to Google Drive from node..."

            # upload the rollup to the node first
            sshv_cmd "$gdrive_node_ip" "sudo mkdir -p /root/Reports/thermal-results" 2>/dev/null
            sshv_scp_to "$gdrive_node_ip" "$lzip" "/tmp/rollup-gdrive.zip"
            sshv_cmd "$gdrive_node_ip" "sudo mv /tmp/rollup-gdrive.zip /root/Reports/thermal-results/${rname}.zip" 2>/dev/null

            local remote_zip="/root/Reports/thermal-results/${rname}.zip"

            # install rclone on node if needed
            local has_rc
            has_rc=$(sshv_cmd "$gdrive_node_ip" "which rclone 2>/dev/null" 2>/dev/null)
            if [[ -z "$has_rc" ]]; then
                log_info "Installing rclone on node..."
                sshv_cmd "$gdrive_node_ip" "curl -s https://rclone.org/install.sh | sudo bash" >/dev/null 2>&1
            fi

            # push SA key
            local sa_file="${SCRIPT_DIR}/gdrive-sa.json"
            sshv_scp_to "$gdrive_node_ip" "$sa_file" "/tmp/.gdrive-sa.json"
            sshv_cmd "$gdrive_node_ip" "sudo chmod 600 /tmp/.gdrive-sa.json"

            # upload from node
            log_info "Uploading ${rname}.zip to Google Drive..."
            local upload_out
            upload_out=$(sshv_cmd "$gdrive_node_ip" \
                "sudo rclone copyto '${remote_zip}' ':drive:${GDRIVE_FOLDER}/${rname}.zip' \
                    --drive-service-account-file /tmp/.gdrive-sa.json \
                    --drive-team-drive '${GDRIVE_TEAM_DRIVE}' \
                    --drive-scope drive -v 2>&1" 2>/dev/null)

            # cleanup
            sshv_cmd "$gdrive_node_ip" "sudo rm -f /tmp/.gdrive-sa.json" 2>/dev/null
            [[ -z "$has_rc" ]] && sshv_cmd "$gdrive_node_ip" "sudo rm -f /usr/bin/rclone /usr/local/bin/rclone" 2>/dev/null

            if echo "$upload_out" | grep -qi "transferred\|copied"; then
                log_success "Uploaded to Google Drive: ${GDRIVE_FOLDER}/${rname}.zip"
            else
                log_warn "Google Drive upload may have failed. Results on node: ${remote_zip}"
            fi
            ;;
        ftp)
            if [[ -n "${FTP_HOST:-}" ]]; then
                log_info "Uploading to FTP..."
                curl --ftp-create-dirs -T "$lzip" \
                    -u "${FTP_USER:-anonymous}:${FTP_PASS:-}" \
                    "ftp://${FTP_HOST}/${FTP_PATH:-/thermal-results}/${rname}.zip" 2>/dev/null
                log_success "Uploaded to ftp://${FTP_HOST}/${FTP_PATH:-/thermal-results}/${rname}.zip"
            fi ;;
    esac

    mkdir -p "$REPORTS_DIR"
    mv "$lzip" "${REPORTS_DIR}/${rname}.zip"
    log_success "Local copy: ${REPORTS_DIR}/${rname}.zip"
}

# ─── Interactive Menu ─────────────────────────────────────────

select_nodes() {
    detect_execution_mode
    if [[ "$EXECUTION_MODE" == "remote" && -z "$CONTROL_PLANE_IP" ]]; then
        echo -e "${CYAN}${BOLD}[1/2] Cluster Access${NC}"
        echo -e "${DIM}  Public IP of any node in the cluster (for sshv)${NC}"
        read -p "  IP: " CONTROL_PLANE_IP

        # test connectivity, auto-detect proxy if needed
        echo -ne "  Testing ${CONTROL_PLANE_IP}: "
        if $SSHV_COMMAND "${DEFAULT_SSH_USER}@${CONTROL_PLANE_IP}" "echo ok" &>/dev/null 2>&1; then
            NODE_CONNECT["$CONTROL_PLANE_IP"]="direct"
            echo -e "${GREEN}direct OK${NC}"
        else
            echo -e "${YELLOW}direct failed${NC}"
            echo -e "  ${DIM}May need jump host (${JUMP_HOST})${NC}"
            read -p "  Private IP for control plane (or 'skip'): " cp_priv
            if [[ "$cp_priv" != "skip" ]]; then
                echo -ne "  Testing via proxy: "
                if $SSHV_COMMAND -o ProxyCommand="$SSHV_COMMAND -W %h:%p ${DEFAULT_SSH_USER}@${JUMP_HOST}" \
                    "${DEFAULT_SSH_USER}@${cp_priv}" "echo ok" &>/dev/null 2>&1; then
                    NODE_CONNECT["$CONTROL_PLANE_IP"]="proxy:${cp_priv}"
                    echo -e "${GREEN}OK via ${JUMP_HOST}${NC}"
                else
                    echo -e "${RED}FAILED${NC}"
                    log_error "Cannot reach control plane"
                    return 1
                fi
            fi
        fi
    fi
    if ! check_kubectl; then return 1; fi
    log_info "Querying cluster for GPU nodes..."
    local ni; ni=$(kubectl_exec get nodes -o wide --no-headers 2>/dev/null)
    [[ -z "$ni" ]] && { log_error "No nodes found"; return 1; }

    NODE_IPS=()
    echo ""
    printf "  ${BOLD}  %-12s %-10s %-18s %s${NC}\n" "NODE" "STATUS" "INTERNAL IP" "GPUs"
    echo -e "  ${DIM}  ──────────────────────────────────────────────${NC}"
    while read -r name status roles age ver iip rest; do
        local gc; gc=$(get_node_gpu_count "$name")
        if [[ "${gc:-0}" -gt 0 ]]; then
            NODE_IPS+=("$name"); IP_MAP_INTERNAL["$name"]="$iip"
            local sc="${GREEN}"; [[ "$status" != "Ready" ]] && sc="${RED}"
            printf "  ${sc}  %-12s %-10s %-18s %s${NC}\n" "$name" "$status" "$iip" "$gc"
        fi
    done <<< "$ni"
    [[ ${#NODE_IPS[@]} -eq 0 ]] && { log_error "No GPU nodes found"; return 1; }
    echo ""; echo -e "  ${GREEN}Found ${#NODE_IPS[@]} GPU node(s)${NC}"
    if [[ ${#NODE_IPS[@]} -gt 1 ]]; then
        read -p "  Run on all ${#NODE_IPS[@]}? (Y/n): " ac
        if [[ "$ac" =~ ^[Nn]$ ]]; then
            read -p "  Node hostnames (space separated): " sel
            NODE_IPS=($(echo "$sel" | tr ',' ' '))
        fi
    fi
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        echo ""; echo -e "  ${CYAN}${BOLD}Public IPs for sshv access${NC} ${DIM}(needed to collect results)${NC}"
        for n in "${NODE_IPS[@]}"; do
            [[ -z "${NODE_PUBLIC_IPS[$n]:-}" ]] && { read -p "  Public IP for ${n}: " pip; NODE_PUBLIC_IPS["$n"]="$pip"; }
        done

        # test connectivity to each node, auto-detect proxy needs
        test_node_connectivity || return 1
    fi
    return 0
}

select_dc_name() {
    DC_NAME="sea1"
    ALTITUDE=220
}

select_output_mode() {
    echo -e "\n${CYAN}${BOLD}[2/2] Output Destination${NC}"
    echo -e "  ${GREEN}1)${NC} Local ${DIM}(stay on each node)${NC}  ${GREEN}2)${NC} Node ${DIM}(scp to one node)${NC}  ${GREEN}3)${NC} Google Drive  ${GREEN}4)${NC} NFS  ${GREEN}5)${NC} FTP"
    read -p "  Choice [1-5]: " oc
    case "$oc" in
        1) OUTPUT_MODE="local" ;;
        2) OUTPUT_MODE="node"
           echo -e "  ${DIM}Enter hostname (e.g. g329) or public IP${NC}"
           read -p "  Collection node: " COLLECT_NODE; COLLECT_USER="root"
           COLLECT_PATH="/root/Reports/thermal-results"; export COLLECT_NODE COLLECT_USER COLLECT_PATH ;;
        3) OUTPUT_MODE="gdrive"
           read -p "  Drive folder [${GDRIVE_FOLDER}]: " gf
           GDRIVE_FOLDER="${gf:-$GDRIVE_FOLDER}" ;;
        4) OUTPUT_MODE="nfs"; read -p "  NFS server: " NFS_SERVER; read -p "  NFS path: " NFS_PATH
           export NFS_SERVER NFS_PATH ;;
        5) OUTPUT_MODE="ftp"; read -p "  FTP host: " FTP_HOST; read -p "  FTP user: " FTP_USER
           read -sp "  FTP password: " FTP_PASS; echo ""; FTP_PATH="/thermal-results"
           export FTP_HOST FTP_USER FTP_PASS FTP_PATH ;;
        *) log_error "Invalid"; return 1 ;;
    esac
}

run_diagnostics_menu() {
    echo ""
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║          Thermal Diagnostics Setup Wizard                ║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${DIM}  2 questions, then it runs hands-off across the entire fleet.${NC}"
    echo ""
    NODE_IPS=(); OUTPUT_MODE=""
    DC_NAME="sea1"; ALTITUDE=220
    select_nodes || return 1
    select_output_mode || return 1

    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  SUMMARY${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Nodes:${NC}     ${#NODE_IPS[@]} (${NODE_IPS[*]})"
    echo -e "  ${CYAN}Site:${NC}      ${DC_NAME} (${ALTITUDE} ft)"
    echo -e "  ${CYAN}Output:${NC}    ${OUTPUT_MODE}"
    case "${OUTPUT_MODE}" in
        node) echo -e "  ${CYAN}Collect:${NC}   ${COLLECT_NODE}" ;; ftp) echo -e "  ${CYAN}FTP:${NC}       ${FTP_HOST}" ;; esac
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo ""
    read -p "  Ready to go? (Y/n): " lc
    [[ "$lc" =~ ^[Nn]$ ]] && { echo "Cancelled."; return 0; }

    echo -e "\n${GREEN}${BOLD}>>> LAUNCHING -- no more prompts, sit back <<<${NC}\n"
    export OUTPUT_MODE DC_NAME ALTITUDE
    if ! check_kubectl; then return 1; fi
    kubectl_exec apply -f "$NAMESPACE_YAML" 2>/dev/null || cat "$NAMESPACE_YAML" | kubectl_exec apply -f - 2>/dev/null

    log_info "Checking container image..."
    local needs=()
    for n in "${NODE_IPS[@]}"; do
        local pip="${NODE_PUBLIC_IPS[$n]:-$CONTROL_PLANE_IP}"
        local hi; hi=$(sshv_cmd "$pip" "sudo crictl images 2>/dev/null | grep -c '$IMAGE_NAME' || echo 0" 2>/dev/null | tr -d '\r')
        [[ "${hi:-0}" == "0" ]] && needs+=("$pip") || echo -e "  ${GREEN}✓${NC} $n"
    done
    if [[ ${#needs[@]} -gt 0 ]]; then
        log_info "${#needs[@]} node(s) need image, building..."
        distribute_image "${needs[@]}" || { log_error "Image distribution failed"; return 1; }
    fi
    launch_jobs "${NODE_IPS[@]}"
}

# ─── Status & Cleanup ────────────────────────────────────────

view_status() {
    check_kubectl || return 1
    echo -e "\n${CYAN}${BOLD}Status${NC}\n"
    kubectl_exec get jobs -n thermal-diagnostics 2>/dev/null || echo "  No jobs"
    echo ""; kubectl_exec get pods -n thermal-diagnostics 2>/dev/null || echo "  No pods"
}

cleanup_jobs() {
    check_kubectl || return 1
    kubectl_exec delete jobs --all -n thermal-diagnostics 2>/dev/null
    log_success "Jobs deleted"
}

create_script_alias() {
    local sp; sp="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local da="thermalk8s" zp="$HOME/.zshrc"
    read -p "Alias name [$da]: " an; an="${an:-$da}"
    cp "$zp" "${zp}.bak.$(date +%s)" 2>/dev/null
    echo "alias ${an}='bash ${sp}'" >> "$zp"
    log_success "Alias '${an}' added. Run: source ~/.zshrc"
}

# ─── CLI Mode ────────────────────────────────────────────────

show_help() {
    echo -e "\n${BOLD}GPU Thermal Diagnostics - K8s Manager v${SCRIPT_VERSION}${NC}\n"
    echo "USAGE:  $SCRIPT_NAME                       Interactive menu"
    echo "        $SCRIPT_NAME run [OPTIONS]          Launch diagnostics"
    echo "        $SCRIPT_NAME status                 View jobs"
    echo "        $SCRIPT_NAME cleanup                Delete jobs"
    echo ""
    echo "RUN OPTIONS:"
    echo "  --nodes \"n1 n2\"          K8s node hostnames"
    echo "  --all-gpu-nodes          All GPU nodes in cluster"
    echo "  --dc-name NAME           DC name (auto-sets altitude)"
    echo "  --output MODE            local|node|nfs|ftp"
    echo "  --collect-node HOST      Collection node (node mode)"
    echo "  --node-ips \"h1:ip1,...\"   Hostname:public-IP mapping"
    echo "  --control-plane IP       Control plane IP (sshv mode)"
    echo "  --kubeconfig FILE        Kubeconfig path"
    echo "  --altitude N             Override altitude (ft)"
    echo "  --ssh-user USER          SSH user (default: vpsupport)"
    echo ""
}

parse_cli_args() {
    local cmd="${1:-}"; shift 2>/dev/null || true
    case "$cmd" in
        run)
            NODE_IPS=()
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --nodes) NODE_IPS=($(echo "$2" | tr ',' ' ')); shift 2 ;;
                    --all-gpu-nodes) check_kubectl || exit 1
                        while read -r nn; do [[ -n "$nn" ]] && NODE_IPS+=("$nn"); done <<< "$(get_all_gpu_nodes)"; shift ;;
                    --control-plane) CONTROL_PLANE_IP="$2"; EXECUTION_MODE="${EXECUTION_MODE:-remote}"; shift 2 ;;
                    --kubeconfig) KUBECONFIG_FILE="$2"; EXECUTION_MODE="kubeconfig"; shift 2 ;;
                    --mode) EXECUTION_MODE="$2"; shift 2 ;;
                    --altitude) ALTITUDE="$2"; shift 2 ;;
                    --dc-name) DC_NAME="$2"
                        if [[ -z "${ALTITUDE:-}" ]]; then
                            case "${DC_NAME,,}" in
                                dfw1*|aln1*) ALTITUDE=656 ;; str1*) ALTITUDE=289 ;;
                                pyl1*) ALTITUDE=220 ;; ftw1*) ALTITUDE=653 ;; esac
                        fi; shift 2 ;;
                    --output) OUTPUT_MODE="$2"; shift 2 ;;
                    --collect-node) COLLECT_NODE="$2"; export COLLECT_NODE; shift 2 ;;
                    --node-ips)
                        local _oldifs="$IFS"; IFS=','
                        for p in $2; do
                            NODE_PUBLIC_IPS["${p%%:*}"]="${p##*:}"
                        done
                        IFS="$_oldifs"; shift 2 ;;
                    --ftp-host) FTP_HOST="$2"; export FTP_HOST; shift 2 ;;
                    --ftp-user) FTP_USER="$2"; export FTP_USER; shift 2 ;;
                    --ftp-pass) FTP_PASS="$2"; export FTP_PASS; shift 2 ;;
                    --ssh-user) DEFAULT_SSH_USER="$2"; shift 2 ;;
                    --gpu-count) DEFAULT_GPU_COUNT="$2"; shift 2 ;;
                    *) log_error "Unknown: $1"; show_help; exit 1 ;;
                esac
            done
            [[ ${#NODE_IPS[@]} -eq 0 ]] && { log_error "No nodes. Use --nodes or --all-gpu-nodes"; exit 1; }
            export OUTPUT_MODE="${OUTPUT_MODE:-local}" DC_NAME="${DC_NAME:-sea1}" ALTITUDE="${ALTITUDE:-220}"
            if [[ -z "$EXECUTION_MODE" ]]; then
                [[ -n "$CONTROL_PLANE_IP" ]] && EXECUTION_MODE="remote"
                [[ -n "$KUBECONFIG_FILE" ]] && EXECUTION_MODE="kubeconfig"
                [[ -z "$EXECUTION_MODE" ]] && detect_execution_mode
            fi
            check_kubectl || exit 1
            kubectl_exec apply -f "$NAMESPACE_YAML" 2>/dev/null || cat "$NAMESPACE_YAML" | kubectl_exec apply -f - 2>/dev/null
            launch_jobs "${NODE_IPS[@]}" ;;
        status) detect_execution_mode; view_status ;;
        cleanup) detect_execution_mode; cleanup_jobs ;;
        --help|-h|help) show_help ;;
        --version|-v) echo "v${SCRIPT_VERSION}" ;;
        *) return 1 ;;
    esac
    return 0
}

# ─── Main Menu ────────────────────────────────────────────────

show_menu() {
    clear
    echo -e "\n${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║  GPU Thermal Diagnostics - K8s Manager (Reflection)     ║${NC}"
    echo -e "${BLUE}${BOLD}║  Version ${SCRIPT_VERSION}                                          ║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${GREEN}${BOLD}1)${NC} Run Thermal Diagnostics  ${DIM}← start here${NC}"
    echo -e "     ${DIM}Quick wizard → auto runs across entire fleet${NC}"
    echo -e "\n  ${GREEN}2)${NC} View Status / Results"
    echo -e "  ${GREEN}3)${NC} Cleanup Jobs"
    echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}a)${NC} Shell alias  ${YELLOW}h)${NC} Help  ${RED}0)${NC} Exit"
    echo -e "${DIM}──────────────────────────────────────────────────────────${NC}\n"
}

run_menu() {
    while true; do
        show_menu; read -p "  Select: " ch
        case "$ch" in
            1) run_diagnostics_menu ;; 2) view_status ;; 3) cleanup_jobs ;;
            a|A) create_script_alias ;; h|H) show_help ;; 0|q|Q) exit 0 ;;
            *) echo -e "  ${RED}Invalid${NC}" ;;
        esac
        echo ""; read -p "Press Enter..." _
    done
}

# ─── Entry Point ──────────────────────────────────────────────

if [[ $# -gt 0 ]]; then parse_cli_args "$@" || run_menu; else run_menu; fi
