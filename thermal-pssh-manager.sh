#!/usr/bin/env bash
# thermal-pssh-manager.sh - GPU Thermal Diagnostics Manager (PSSH)
# Deploys thermal diagnostics directly to bare-metal nodes via parallel-ssh
# Version 1.0.0

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

THERMAL_SCRIPT="${SCRIPT_DIR}/thermal-diagnostics-2.6.2-vp.sh"
REPORTS_DIR="${HOME}/Reports/thermal-diagnostics"

DC_NAME="sea1"
ALTITUDE=220

SSH_USER=""
SSH_KEY=""
NODE_IPS=()
OUTPUT_MODE="local"
COLLECT_NODE=""
GDRIVE_TEAM_DRIVE="0AEnvoKAUzsPmUk9PVA"
GDRIVE_FOLDER="thermal-results"
JUMP_HOST="10.9.231.200"

# per-node connection method cache: ip -> "direct" or "proxy:private_ip"
declare -A NODE_CONNECT

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

HISTORY_FILE="/tmp/.thermal-pssh-history.cache"

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

save_history() {
    cat > "$HISTORY_FILE" << EOF
SSH_USER="$SSH_USER"
SSH_KEY="$SSH_KEY"
NODE_IPS_STR="${NODE_IPS[*]}"
OUTPUT_MODE="$OUTPUT_MODE"
COLLECT_NODE="$COLLECT_NODE"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M')"
EOF
}

load_history() {
    [[ ! -f "$HISTORY_FILE" ]] && return 1
    source "$HISTORY_FILE" 2>/dev/null
    NODE_IPS=($NODE_IPS_STR)
    return 0
}

# ─── Prerequisites ────────────────────────────────────────────

check_pssh() {
    if command -v parallel-ssh &>/dev/null; then
        PSSH_CMD="parallel-ssh"; PSCP_CMD="parallel-scp"
    elif command -v pssh &>/dev/null; then
        PSSH_CMD="pssh"; PSCP_CMD="pscp"
    else
        log_error "parallel-ssh (pssh) not found. Install with: brew install pssh"
        return 1
    fi
    return 0
}

SSH_OPTS_STR="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"

# get the SSH options for a node (direct or via proxy)
_ssh_opts_for() {
    local host="$1"
    local method="${NODE_CONNECT[$host]:-direct}"
    local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15"
    if [[ "$method" == proxy:* ]]; then
        local priv_ip="${method#proxy:}"
        echo "$opts -o ProxyCommand=\"sshv -W %h:%p ${DEFAULT_SSH_USER:-vpsupport}@${JUMP_HOST}\" -i $SSH_KEY ${SSH_USER}@${priv_ip}"
    else
        echo "$opts -i $SSH_KEY ${SSH_USER}@${host}"
    fi
}

# resolve the target user@host for a node (handles proxy)
_ssh_target() {
    local host="$1"
    local method="${NODE_CONNECT[$host]:-direct}"
    if [[ "$method" == proxy:* ]]; then
        echo "${method#proxy:}"
    else
        echo "$host"
    fi
}

ssh_cmd() {
    local host="$1"; shift
    local method="${NODE_CONNECT[$host]:-direct}"
    local attempt
    for attempt in 1 2 3; do
        local result rc
        if [[ "$method" == proxy:* ]]; then
            local priv_ip="${method#proxy:}"
            result=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
                -o ConnectTimeout=15 -o ServerAliveInterval=30 \
                -o ProxyCommand="sshv -W %h:%p ${DEFAULT_SSH_USER:-vpsupport}@${JUMP_HOST}" \
                -i "$SSH_KEY" "${SSH_USER}@${priv_ip}" "$@" 2>/dev/null)
            rc=$?
        else
            result=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
                -o ConnectTimeout=15 -o ServerAliveInterval=30 \
                -i "$SSH_KEY" "${SSH_USER}@${host}" "$@" 2>/dev/null)
            rc=$?
        fi
        if [[ $rc -eq 0 ]]; then echo "$result"; return 0; fi
        [[ $attempt -lt 3 ]] && sleep 2
    done
    return 1
}

scp_from() {
    local host="$1" remote="$2" local_path="$3"
    local method="${NODE_CONNECT[$host]:-direct}"
    if [[ "$method" == proxy:* ]]; then
        local priv_ip="${method#proxy:}"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
            -o ProxyCommand="sshv -W %h:%p ${DEFAULT_SSH_USER:-vpsupport}@${JUMP_HOST}" \
            -i "$SSH_KEY" "${SSH_USER}@${priv_ip}:${remote}" "$local_path" 2>/dev/null
    else
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
            -i "$SSH_KEY" "${SSH_USER}@${host}:${remote}" "$local_path" 2>/dev/null
    fi
}

scp_to() {
    local host="$1" local_path="$2" remote="$3"
    local method="${NODE_CONNECT[$host]:-direct}"
    if [[ "$method" == proxy:* ]]; then
        local priv_ip="${method#proxy:}"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
            -o ProxyCommand="sshv -W %h:%p ${DEFAULT_SSH_USER:-vpsupport}@${JUMP_HOST}" \
            -i "$SSH_KEY" "$local_path" "${SSH_USER}@${priv_ip}:${remote}" 2>/dev/null
    else
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
            -i "$SSH_KEY" "$local_path" "${SSH_USER}@${host}:${remote}" 2>/dev/null
    fi
}

# test connectivity to all nodes at startup, prompt for private IP if direct fails
test_all_nodes_connectivity() {
    echo -e "\n  ${CYAN}Testing SSH connectivity to all nodes...${NC}"
    local all_ok=true
    for ip in "${NODE_IPS[@]}"; do
        echo -ne "  ${ip}: "
        # try direct first
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
            -o ConnectTimeout=5 -i "$SSH_KEY" "${SSH_USER}@${ip}" "echo ok" &>/dev/null; then
            NODE_CONNECT["$ip"]="direct"
            echo -e "${GREEN}direct SSH OK${NC}"
        else
            echo -e "${YELLOW}direct failed${NC}"
            echo -e "  ${DIM}This node may require SSH via jump host (${JUMP_HOST})${NC}"
            read -p "  Enter private IP for ${ip} (or 'skip' to exclude): " priv_ip
            if [[ "$priv_ip" == "skip" ]]; then
                echo -e "  ${RED}Skipping ${ip}${NC}"
                # remove from NODE_IPS
                NODE_IPS=("${NODE_IPS[@]/$ip}")
                continue
            fi
            # test via proxy
            echo -ne "  Testing via proxy (${priv_ip}): "
            if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
                -o ConnectTimeout=10 \
                -o ProxyCommand="sshv -W %h:%p ${DEFAULT_SSH_USER:-vpsupport}@${JUMP_HOST}" \
                -i "$SSH_KEY" "${SSH_USER}@${priv_ip}" "echo ok" &>/dev/null; then
                NODE_CONNECT["$ip"]="proxy:${priv_ip}"
                echo -e "${GREEN}OK via ${JUMP_HOST} → ${priv_ip}${NC}"
            else
                echo -e "${RED}FAILED${NC}"
                log_error "Cannot reach ${ip} directly or via proxy"
                all_ok=false
            fi
        fi
    done

    # clean empty entries from NODE_IPS
    local clean=()
    for ip in "${NODE_IPS[@]}"; do [[ -n "$ip" ]] && clean+=("$ip"); done
    NODE_IPS=("${clean[@]}")

    [[ ${#NODE_IPS[@]} -eq 0 ]] && { log_error "No reachable nodes"; return 1; }
    [[ "$all_ok" == "false" ]] && return 1
    return 0
}

# push the google service account key to a remote node
push_gdrive_sa_key() {
    local host="$1"
    local sa_file="${SCRIPT_DIR}/gdrive-sa.json"
    if [[ ! -f "$sa_file" ]]; then
        # try k8s-setup dir as fallback
        sa_file="${SCRIPT_DIR}/k8s-setup/gdrive-sa.json"
    fi
    if [[ ! -f "$sa_file" ]]; then
        log_error "Google Drive service account key not found. Place gdrive-sa.json next to this script."
        return 1
    fi
    scp_to "$host" "$sa_file" "/tmp/.gdrive-sa.json"
    ssh_cmd "$host" "sudo chmod 600 /tmp/.gdrive-sa.json"
}

# upload a file to google team drive via rclone on a remote node
gdrive_upload_from_node() {
    local host="$1" file_path="$2" dest_folder="$3"
    local fname; fname=$(basename "$file_path")

    # install rclone if not present
    local has_rclone
    has_rclone=$(ssh_cmd "$host" "which rclone 2>/dev/null")
    if [[ -z "$has_rclone" ]]; then
        log_info "Installing rclone on ${host}..."
        ssh_cmd "$host" "curl -s https://rclone.org/install.sh | sudo bash" >/dev/null
    fi

    # push service account key
    push_gdrive_sa_key "$host"

    # upload using rclone with inline backend flags (no config file needed)
    log_info "Uploading ${fname} to Google Drive..."
    local result
    result=$(ssh_cmd "$host" "sudo rclone copyto '${file_path}' ':drive:${dest_folder}/${fname}' \
        --drive-service-account-file /tmp/.gdrive-sa.json \
        --drive-team-drive '${GDRIVE_TEAM_DRIVE}' \
        --drive-scope drive \
        -v 2>&1")
    local rc=$?

    # cleanup: remove SA key and rclone
    ssh_cmd "$host" "sudo rm -f /tmp/.gdrive-sa.json"
    if [[ -z "$has_rclone" ]]; then
        ssh_cmd "$host" "sudo rm -f /usr/bin/rclone /usr/local/bin/rclone" 2>/dev/null
    fi

    if [[ $rc -eq 0 ]] && echo "$result" | grep -qi "transferred\|copied"; then
        return 0
    else
        echo "$result" >&2
        return 1
    fi
}

write_hosts_file() {
    local hfile="/tmp/thermal-pssh-hosts-$$.txt"
    for ip in "${NODE_IPS[@]}"; do
        echo "$ip"
    done > "$hfile"
    echo "$hfile"
}

# ─── Deploy & Run ─────────────────────────────────────────────

deploy_and_run() {
    local hosts_file
    hosts_file=$(write_hosts_file)
    local total=${#NODE_IPS[@]}

    echo -e "\n${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║           Launching Thermal Diagnostics (PSSH)             ║${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}Nodes:${NC}     $total"
    echo -e "  ${CYAN}User:${NC}      ${SSH_USER}"
    echo -e "  ${CYAN}Key:${NC}       $(basename ${SSH_KEY})"
    echo -e "  ${CYAN}Site:${NC}      ${DC_NAME} (${ALTITUDE} ft)"
    case "${OUTPUT_MODE}" in
        local)  echo -e "  ${CYAN}Save to:${NC}   ${YELLOW}Each node${NC} → /root/TDAS/" ;;
        node)   echo -e "  ${CYAN}Save to:${NC}   ${YELLOW}${COLLECT_NODE}${NC} → /root/Reports/thermal-results/" ;;
        gdrive) echo -e "  ${CYAN}Save to:${NC}   ${YELLOW}Google Drive${NC} → ${GDRIVE_FOLDER}/" ;;
        ftp)    echo -e "  ${CYAN}Save to:${NC}   ${YELLOW}FTP${NC} → ${FTP_HOST}:${FTP_PATH:-/thermal-results}/" ;;
    esac
    echo ""

    # split nodes into direct and proxy groups
    local direct_hosts=() proxy_hosts=()
    for ip in "${NODE_IPS[@]}"; do
        if [[ "${NODE_CONNECT[$ip]:-direct}" == "direct" ]]; then
            direct_hosts+=("$ip")
        else
            proxy_hosts+=("$ip")
        fi
    done

    # clean old files
    if [[ ${#direct_hosts[@]} -gt 0 ]]; then
        local dfile="/tmp/thermal-direct-hosts-$$.txt"
        printf '%s\n' "${direct_hosts[@]}" > "$dfile"
        $PSSH_CMD -h "$dfile" -l "$SSH_USER" -x "-i $SSH_KEY $SSH_OPTS_STR" \
            -t 10 "sudo rm -f /tmp/thermal_diag.sh /tmp/thermal_wrapper.sh /tmp/.thermal-status" >/dev/null 2>&1
    fi
    for ip in "${proxy_hosts[@]}"; do
        ssh_cmd "$ip" "sudo rm -f /tmp/thermal_diag.sh /tmp/thermal_wrapper.sh /tmp/.thermal-status" </dev/null 2>/dev/null
    done

    # upload thermal script
    log_info "Uploading thermal script to $total node(s)..."
    if [[ ${#direct_hosts[@]} -gt 0 ]]; then
        $PSCP_CMD -h "$dfile" -l "$SSH_USER" -x "-i $SSH_KEY $SSH_OPTS_STR" \
            "$THERMAL_SCRIPT" /tmp/thermal_diag.sh 2>&1 | grep -E "SUCCESS|FAILURE"
    fi
    for ip in "${proxy_hosts[@]}"; do
        echo -ne "  ${ip} (via proxy): "
        if scp_to "$ip" "$THERMAL_SCRIPT" /tmp/thermal_diag.sh; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done

    # create wrapper script that runs non-interactively and writes status updates
    local wrapper="/tmp/thermal-wrapper-$$.sh"
    cat > "$wrapper" << 'WRAPPER_EOF'
#!/bin/bash
export altitude_ft=__ALTITUDE__
export NON_INTERACTIVE=true
export AUTO_STOP_SERVICES=true
export AUTO_KILL_GPU_PROCESSES=true

# write live status to a file the manager can poll
STATUS_FILE="/tmp/.thermal-status"
trap 'echo "done" > $STATUS_FILE' EXIT

echo "starting" > $STATUS_FILE
sudo -E bash /tmp/thermal_diag.sh --local 2>&1 | while IFS= read -r line; do
    echo "$line"
    # update status based on output
    case "$line" in
        *"fan speed"*|*"Fan"*|*"package"*|*"install"*) echo "setup" > $STATUS_FILE ;;
        *"GPU "*Temperature*|*"°C"*) echo "gpu-stress" > $STATUS_FILE ;;
        *"TSR collection progress"*) pct=$(echo "$line" | grep -o '[0-9]*$'); echo "tsr:${pct}" > $STATUS_FILE ;;
        *"Cooldown"*) echo "cooldown" > $STATUS_FILE ;;
        *"Processing"*|*"merging"*) echo "processing" > $STATUS_FILE ;;
        *"results are saved"*|*"Results zip"*|*"Script finalizing"*) echo "complete" > $STATUS_FILE ;;
        *"Script failed"*|*"ERROR"*) echo "failed" > $STATUS_FILE ;;
    esac
done
WRAPPER_EOF
    # inject altitude
    sed -i.bak "s/__ALTITUDE__/$ALTITUDE/" "$wrapper" && rm -f "${wrapper}.bak"

    log_info "Uploading run wrapper..."
    if [[ ${#direct_hosts[@]} -gt 0 ]]; then
        $PSCP_CMD -h "$dfile" -l "$SSH_USER" -x "-i $SSH_KEY $SSH_OPTS_STR" \
            "$wrapper" /tmp/thermal_wrapper.sh 2>&1 | grep -E "SUCCESS|FAILURE"
    fi
    for ip in "${proxy_hosts[@]}"; do
        scp_to "$ip" "$wrapper" /tmp/thermal_wrapper.sh </dev/null 2>/dev/null
    done
    rm -f "$wrapper" "$dfile" 2>/dev/null

    # run on all nodes in parallel
    log_info "Starting thermal test on all nodes (this takes ~25-30 min)..."
    echo ""

    local outdir="/tmp/thermal-pssh-output-$$"
    mkdir -p "$outdir"

    # launch direct nodes via pssh
    if [[ ${#direct_hosts[@]} -gt 0 ]]; then
        local dfile2="/tmp/thermal-direct-hosts2-$$.txt"
        printf '%s\n' "${direct_hosts[@]}" > "$dfile2"
        $PSSH_CMD -h "$dfile2" -l "$SSH_USER" -x "-i $SSH_KEY $SSH_OPTS_STR" \
            -t 3600 -o "$outdir" -e "$outdir" \
            "chmod +x /tmp/thermal_wrapper.sh && bash /tmp/thermal_wrapper.sh" >/dev/null 2>&1 &
        rm -f "$dfile2" 2>/dev/null
    fi

    # launch proxy nodes individually in background
    for ip in "${proxy_hosts[@]}"; do
        ssh_cmd "$ip" "chmod +x /tmp/thermal_wrapper.sh && bash /tmp/thermal_wrapper.sh" </dev/null > "$outdir/$ip" 2>&1 &
    done

    local pssh_pid=$!

    # track per-node state
    declare -A node_state
    for ip in "${NODE_IPS[@]}"; do node_state["$ip"]="running"; done

    local start_time; start_time=$(date +%s)

    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"

    # wait for any background job (pssh or individual proxy ssh)
    while jobs -r 2>/dev/null | grep -q .; do
        local elapsed=$(( $(date +%s) - start_time ))
        local mins=$((elapsed / 60)) secs=$((elapsed % 60))

        local done_count=0 fail_count=0 run_count=0
        local status_line=""

        for ip in "${NODE_IPS[@]}"; do
            if [[ "${node_state[$ip]}" == "done" ]]; then
                done_count=$((done_count + 1)); continue
            elif [[ "${node_state[$ip]}" == "failed" ]]; then
                fail_count=$((fail_count + 1)); continue
            fi

            # poll the status file directly from the node via SSH
            local st
            st=$(ssh_cmd "$ip" "cat /tmp/.thermal-status 2>/dev/null" </dev/null | tr -d '\r')

            case "$st" in
                complete|done)
                    node_state["$ip"]="done"
                    done_count=$((done_count + 1))
                    echo -e "\033[2K\r  ${GREEN}✓${NC} $ip completed"
                    ;;
                failed)
                    node_state["$ip"]="failed"
                    fail_count=$((fail_count + 1))
                    local reason
                    reason=$(ssh_cmd "$ip" "grep -E 'ERROR:.*SRV|ERROR:.*RAC|Reason:' /tmp/thermal-pssh-output-*/. 2>/dev/null | tail -1 | head -c 70" </dev/null | tr -d '\r')
                    echo -e "\033[2K\r  ${RED}✗${NC} $ip FAILED: ${reason:-unknown}"
                    ;;
                tsr:*)
                    run_count=$((run_count + 1))
                    status_line+="  ${ip}: TSR ${st#tsr:}%"
                    ;;
                gpu-stress)  run_count=$((run_count + 1)); status_line+="  ${ip}: GPU stress" ;;
                processing)  run_count=$((run_count + 1)); status_line+="  ${ip}: processing" ;;
                cooldown)    run_count=$((run_count + 1)); status_line+="  ${ip}: cooldown" ;;
                setup)       run_count=$((run_count + 1)); status_line+="  ${ip}: setup" ;;
                starting)    run_count=$((run_count + 1)); status_line+="  ${ip}: starting" ;;
                *)           run_count=$((run_count + 1)); status_line+="  ${ip}: running" ;;
            esac
        done

        echo -ne "\033[2K\r"
        echo -ne "  \033[0;36m$(printf '%02d:%02d' $mins $secs)\033[0m  ${done_count}/${total} done  ${fail_count} failed \033[2m|\033[0m${status_line}"

        sleep 30
    done
    wait
    local pssh_exit=$?

    echo ""
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    echo ""

    if [[ $pssh_exit -eq 0 ]]; then
        log_success "All nodes completed"
    else
        log_warn "Some nodes had issues"
    fi

    # show per-node status with failure reasons
    local succeeded=0 node_failed=0
    for ip in "${NODE_IPS[@]}"; do
        local stdout_file="$outdir/$ip"
        local stderr_file="$outdir/$ip"  # pssh puts stderr in same dir with -e

        # check status file first, fall back to pssh output, fall back to node_state from monitor
        local node_st="${node_state[$ip]:-unknown}"
        if [[ "$node_st" != "done" && "$node_st" != "failed" ]]; then
            node_st=$(ssh_cmd "$ip" "cat /tmp/.thermal-status 2>/dev/null" </dev/null | tr -d '\r')
        fi
        if [[ -z "$node_st" || "$node_st" == "unknown" ]]; then
            # fall back to pssh output
            if [[ -f "$stdout_file" ]] && grep -q "results are saved\|Script finalizing\|Results zip" "$stdout_file" 2>/dev/null; then
                node_st="complete"
            fi
        fi

        if [[ "$node_st" == "complete" || "$node_st" == "done" ]]; then
            echo -e "  ${GREEN}✓${NC} $ip -- completed"
            succeeded=$((succeeded + 1))
        else
            node_failed=$((node_failed + 1))
            echo -e "  ${RED}✗${NC} $ip -- FAILED"
            local reason=""
            if [[ -f "$stdout_file" ]]; then
                reason=$(grep -E "^ERROR:|ERROR:.*SRV|ERROR:.*RAC|Reason:" "$stdout_file" 2>/dev/null \
                    | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | head -c 80)
            fi
            echo -e "     ${DIM}Reason: ${reason:-unknown}${NC}"
        fi
    done

    echo ""
    echo -e "  ${CYAN}Results:${NC} ${succeeded} succeeded, ${node_failed} failed"

    rm -f "$hosts_file"
    echo ""

    # collect results
    collect_results "$outdir"
    rm -rf "$outdir"
}

# ─── Results Collection ──────────────────────────────────────

collect_results() {
    local outdir="$1"
    local rts; rts=$(date +%Y%m%d-%H%M%S)
    local rname="${DC_NAME}-${rts}"
    local remote_rollup="/root/Reports/thermal-results/${rname}"

    # cleanup wrapper scripts on all nodes
    for ip in "${NODE_IPS[@]}"; do
        ssh_cmd "$ip" "rm -f /tmp/thermal_diag.sh /tmp/thermal_wrapper.sh" 2>/dev/null &
    done
    wait

    case "${OUTPUT_MODE}" in
        node)   collect_to_node "$rname" "$remote_rollup" ;;
        gdrive) collect_to_node_then_gdrive "$rname" "$remote_rollup" ;;
        ftp)    collect_to_local_then_upload "$rname" "ftp" ;;
        local)  log_info "Results saved on each node at /root/TDAS/"; return 0 ;;
    esac
}

# node mode: push SSH key to collection node, have it pull from each worker directly
collect_to_node() {
    local rname="$1" remote_rollup="$2"

    log_info "Collecting results directly on ${COLLECT_NODE}..."

    # push the SSH key to the collection node so it can pull from workers
    ssh_cmd "$COLLECT_NODE" "sudo mkdir -p /root/.thermal-key /root/Reports/thermal-results/${rname}"
    scp_to "$COLLECT_NODE" "$SSH_KEY" "/tmp/.thermal-collect-key"
    ssh_cmd "$COLLECT_NODE" "sudo mv /tmp/.thermal-collect-key /root/.thermal-key/id && sudo chmod 600 /root/.thermal-key/id"

    # resolve internal IPs for node-to-node SCP (public IPs don't work between nodes)
    declare -A INTERNAL_IPS
    for ip in "${NODE_IPS[@]}"; do
        local iip
        iip=$(ssh_cmd "$ip" "hostname -I | awk '{print \$1}'" | tr -d '\r')
        INTERNAL_IPS["$ip"]="${iip:-$ip}"
    done

    local collected=0
    for ip in "${NODE_IPS[@]}"; do
        echo -e "  ${YELLOW}→${NC} ${ip}..."

        # get the zip path and node name
        local rzip hn st
        rzip=$(ssh_cmd "$ip" "sudo bash -c 'ls -t /root/TDAS/dcgmprof-*.zip 2>/dev/null | head -1'" | tr -d '\r')
        [[ -z "$rzip" ]] && { log_warn "No results on $ip"; continue; }
        hn=$(ssh_cmd "$ip" "hostname -s" | tr -d '\r'); hn="${hn:-$ip}"
        st=$(basename "$rzip" | sed -E 's/^dcgmprof-([^-]+)-.*/\1/')
        [[ "$st" == "$(basename "$rzip")" ]] && st="UNKNOWN"
        local nzn="${hn}-${st}.zip"

        if [[ "$ip" == "$COLLECT_NODE" ]]; then
            # same node, just copy locally
            ssh_cmd "$COLLECT_NODE" "sudo cp '$rzip' '${remote_rollup}/${nzn}'"
        else
            # stage file readable on worker, collection node pulls via INTERNAL IP
            local worker_internal="${INTERNAL_IPS[$ip]}"
            ssh_cmd "$ip" "sudo cp '$rzip' /tmp/thermal-collect.zip && sudo chmod 644 /tmp/thermal-collect.zip" </dev/null
            ssh_cmd "$COLLECT_NODE" "sudo scp -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i /root/.thermal-key/id ${SSH_USER}@${worker_internal}:/tmp/thermal-collect.zip '${remote_rollup}/${nzn}'" </dev/null
            ssh_cmd "$ip" "rm -f /tmp/thermal-collect.zip" </dev/null
        fi

        # verify
        local verify
        verify=$(ssh_cmd "$COLLECT_NODE" "sudo ls -lh '${remote_rollup}/${nzn}' 2>/dev/null" | tr -d '\r')
        if [[ -n "$verify" ]]; then
            local zs; zs=$(echo "$verify" | awk '{print $5}')
            echo -e "  ${GREEN}✓${NC} ${nzn} (${zs})"
            collected=$((collected + 1))
        else
            log_warn "Failed to collect from $ip"
        fi
    done

    # cleanup the temp key
    ssh_cmd "$COLLECT_NODE" "sudo rm -rf /root/.thermal-key"

    [[ $collected -eq 0 ]] && { log_error "No results collected"; return 1; }

    # create rollup zip on the collection node
    local remote_zip="/root/Reports/thermal-results/${rname}.zip"
    log_info "Creating rollup on ${COLLECT_NODE}..."
    ssh_cmd "$COLLECT_NODE" "sudo bash -c 'cd /root/Reports/thermal-results && zip -r ${rname}.zip ${rname}/ >/dev/null 2>&1 && rm -rf ${rname}/'"

    # verify and display
    local info
    info=$(ssh_cmd "$COLLECT_NODE" "sudo ls -lh '${remote_zip}' 2>/dev/null && echo '---' && sudo unzip -l '${remote_zip}' 2>/dev/null | grep -E '\.zip$'" | tr -d '\r')

    local fsz; fsz=$(echo "$info" | head -1 | awk '{print $5}')
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  RESULTS READY${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Location:${NC} ${COLLECT_NODE}:${remote_zip}"
    echo -e "  ${CYAN}Size:${NC}     ${fsz}"
    echo -e "  ${CYAN}Nodes:${NC}    ${collected}"
    echo -e "${DIM}Contents:${NC}"
    echo "$info" | grep -E '\.zip$' | while read -r sz dt tm nm; do
        echo -e "  ${CYAN}•${NC} $nm"
    done
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
}

# gdrive mode: collect to first node, create rollup, upload to Google Drive via rclone
collect_to_node_then_gdrive() {
    local rname="$1" remote_rollup="$2"
    local gdrive_node="${NODE_IPS[0]}"

    log_info "Collecting results on ${gdrive_node}, then uploading to Google Drive..."

    local orig_collect="$COLLECT_NODE"
    COLLECT_NODE="$gdrive_node"
    collect_to_node "$rname" "$remote_rollup"
    local collect_status=$?
    COLLECT_NODE="$orig_collect"

    [[ $collect_status -ne 0 ]] && return 1

    local remote_zip="/root/Reports/thermal-results/${rname}.zip"

    if gdrive_upload_from_node "$gdrive_node" "$remote_zip" "$GDRIVE_FOLDER"; then
        echo ""
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}${BOLD}  UPLOADED TO GOOGLE DRIVE${NC}"
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${CYAN}Drive:${NC}  ${GDRIVE_FOLDER}/${rname}.zip"
        echo -e "  ${CYAN}Node:${NC}   ${gdrive_node}:${remote_zip}"
        echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    else
        log_error "Google Drive upload failed"
        echo -e "  ${DIM}Results still on ${gdrive_node}:${remote_zip}${NC}"
    fi
}

# ftp mode: collect to local, then upload
collect_to_local_then_upload() {
    local rname="$1" mode="$2"
    local rdir="/tmp/${rname}"
    mkdir -p "$rdir"

    log_info "Collecting results..."

    local collected=0
    for ip in "${NODE_IPS[@]}"; do
        echo -e "  ${YELLOW}→${NC} ${ip}..."
        local rzip hn st
        rzip=$(ssh_cmd "$ip" "sudo bash -c 'ls -t /root/TDAS/dcgmprof-*.zip 2>/dev/null | head -1'" | tr -d '\r')
        [[ -z "$rzip" ]] && { log_warn "No results on $ip"; continue; }
        hn=$(ssh_cmd "$ip" "hostname -s" | tr -d '\r'); hn="${hn:-$ip}"
        st=$(basename "$rzip" | sed -E 's/^dcgmprof-([^-]+)-.*/\1/')
        [[ "$st" == "$(basename "$rzip")" ]] && st="UNKNOWN"
        local nzn="${hn}-${st}.zip"

        ssh_cmd "$ip" "sudo cp '$rzip' /tmp/thermal-dl.zip && sudo chmod 644 /tmp/thermal-dl.zip"
        scp_from "$ip" "/tmp/thermal-dl.zip" "${rdir}/${nzn}"
        ssh_cmd "$ip" "rm -f /tmp/thermal-dl.zip"

        [[ -f "${rdir}/${nzn}" ]] && { echo -e "  ${GREEN}✓${NC} ${nzn}"; collected=$((collected + 1)); } || log_warn "Download failed from $ip"
    done

    [[ $collected -eq 0 ]] && { log_error "No results collected"; rm -rf "$rdir"; return 1; }

    local lzip="/tmp/${rname}.zip"
    (cd /tmp && zip -r "$lzip" "${rname}/" >/dev/null 2>&1)
    rm -rf "$rdir"

    local fsz; fsz=$(du -h "$lzip" | cut -f1)
    local dest_display=""

    if [[ "$mode" == "s3" ]]; then
        local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${rname}.zip"
        log_info "Uploading to S3..."
        if aws --profile "$AWS_PROFILE" s3 cp "$lzip" "$s3_path" 2>&1; then
            dest_display="$s3_path"
            log_success "Uploaded to S3"
        else
            log_warn "S3 upload failed, results saved locally"
        fi
    elif [[ "$mode" == "ftp" && -n "${FTP_HOST:-}" ]]; then
        log_info "Uploading to FTP..."
        curl --ftp-create-dirs -T "$lzip" \
            -u "${FTP_USER:-anonymous}:${FTP_PASS:-}" \
            "ftp://${FTP_HOST}/${FTP_PATH:-/thermal-results}/${rname}.zip" 2>/dev/null
        dest_display="ftp://${FTP_HOST}/${FTP_PATH:-/thermal-results}/${rname}.zip"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  RESULTS READY${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    [[ -n "$dest_display" ]] && echo -e "  ${CYAN}Location:${NC} ${dest_display}"
    echo -e "  ${CYAN}Size:${NC}     ${fsz}"
    echo -e "  ${CYAN}Nodes:${NC}    ${collected}"
    echo -e "${DIM}Contents:${NC}"
    unzip -l "$lzip" 2>/dev/null | grep -E '\.zip$' | while read -r sz dt tm nm; do
        echo -e "  ${CYAN}•${NC} $nm"
    done
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"

    mkdir -p "$REPORTS_DIR"
    mv "$lzip" "${REPORTS_DIR}/${rname}.zip" 2>/dev/null
    log_success "Local copy: ${REPORTS_DIR}/${rname}.zip"
}

# ─── Interactive Menu ─────────────────────────────────────────

select_nodes_and_auth() {
    echo -e "${CYAN}${BOLD}[1/2] Nodes & SSH Access${NC}"

    # SSH user
    read -p "  SSH username: " SSH_USER
    [[ -z "$SSH_USER" ]] && { log_error "Username required"; return 1; }

    # SSH key -- scan and present menu
    local keys=()
    local key_labels=()
    while IFS= read -r kf; do
        # skip public keys, certs, non-key files
        [[ "$kf" == *.pub ]] && continue
        [[ "$kf" == *.crt ]] && continue
        [[ "$kf" == *known_hosts* ]] && continue
        [[ "$kf" == *authorized_keys* ]] && continue
        [[ "$kf" == *config* ]] && continue
        [[ ! -f "$kf" ]] && continue
        # check it looks like a private key
        if head -1 "$kf" 2>/dev/null | grep -qE "PRIVATE KEY|OPENSSH"; then
            keys+=("$kf")
            local bn; bn=$(basename "$kf")
            local ktype; ktype=$(ssh-keygen -l -f "$kf" 2>/dev/null | awk '{print $4}' | tr -d '()')
            key_labels+=("${bn} ${DIM}(${ktype:-unknown})${NC}")
        fi
    done < <(find ~/.ssh -maxdepth 1 -type f 2>/dev/null | sort)

    if [[ ${#keys[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${CYAN}Available SSH keys:${NC}"
        for i in "${!keys[@]}"; do
            echo -e "    ${GREEN}$((i+1)))${NC} ${key_labels[$i]}"
        done
        echo -e "    ${GREEN}$((${#keys[@]}+1)))${NC} Enter path manually"
        echo ""
        read -p "  Select key [1-$((${#keys[@]}+1))]: " key_choice

        if [[ "$key_choice" =~ ^[0-9]+$ ]] && [[ "$key_choice" -ge 1 ]] && [[ "$key_choice" -le "${#keys[@]}" ]]; then
            SSH_KEY="${keys[$((key_choice-1))]}"
        else
            read -e -p "  Key path: " SSH_KEY
            SSH_KEY="${SSH_KEY/#\~/$HOME}"
        fi
    else
        echo -e "  ${DIM}No keys found in ~/.ssh, enter path manually:${NC}"
        read -e -p "  Key path: " SSH_KEY
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
    fi

    [[ ! -f "$SSH_KEY" ]] && { log_error "Key not found: $SSH_KEY"; return 1; }
    echo -e "  ${GREEN}Using: $(basename "$SSH_KEY")${NC}"

    # test SSH connectivity with first node before asking for all
    echo ""
    echo -e "  ${DIM}Enter node IPs (space/comma/newline separated, or a file path)${NC}"
    echo -e "  ${DIM}Blank line when done:${NC}"
    local all_input=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        all_input+=" $line"
    done

    local trimmed; trimmed=$(echo "$all_input" | xargs)
    if [[ -f "$trimmed" ]]; then
        NODE_IPS=($(grep -v '^#' "$trimmed" | grep -v '^$' | tr ',' ' ' | tr -s ' '))
        echo -e "  ${GREEN}Loaded from file: $trimmed${NC}"
    else
        NODE_IPS=($(echo "$all_input" | tr ',' ' ' | tr -s ' '))
    fi

    [[ ${#NODE_IPS[@]} -eq 0 ]] && { log_error "No nodes provided"; return 1; }
    echo -e "  ${GREEN}${#NODE_IPS[@]} node(s)${NC}"

    # test SSH to every node, auto-detect proxy needs
    test_all_nodes_connectivity || return 1
}

select_output() {
    echo -e "\n${CYAN}${BOLD}[2/2] Output Destination${NC}"
    echo -e "  ${GREEN}1)${NC} Local ${DIM}(stay on each node)${NC}  ${GREEN}2)${NC} Node ${DIM}(collect to one node)${NC}  ${GREEN}3)${NC} Google Drive  ${GREEN}4)${NC} FTP"
    read -p "  Choice [1-4]: " oc
    case "$oc" in
        1) OUTPUT_MODE="local" ;;
        2) OUTPUT_MODE="node"
           read -p "  Collection node IP: " COLLECT_NODE ;;
        3) OUTPUT_MODE="gdrive"
           read -p "  Drive folder [${GDRIVE_FOLDER}]: " gf
           GDRIVE_FOLDER="${gf:-$GDRIVE_FOLDER}" ;;
        4) OUTPUT_MODE="ftp"
           read -p "  FTP host: " FTP_HOST; read -p "  FTP user: " FTP_USER
           read -sp "  FTP password: " FTP_PASS; echo ""
           FTP_PATH="/thermal-results"; export FTP_HOST FTP_USER FTP_PASS FTP_PATH ;;
        *) log_error "Invalid"; return 1 ;;
    esac
}

run_diagnostics_menu() {
    echo ""
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║       Thermal Diagnostics - PSSH Manager                ║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}  Before you begin, make sure you have:${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} A list of node IPs to test (or a file with one IP per line)"
    echo -e "  ${CYAN}2.${NC} An SSH key authorized on ${BOLD}every${NC} node to be tested"
    echo -e "  ${CYAN}3.${NC} The SSH username that has ${BOLD}passwordless sudo${NC} on each node"
    echo -e "  ${CYAN}4.${NC} No running GPU workloads on the target nodes"
    echo ""
    echo -e "${DIM}  The script will upload the thermal test to each node, run it in${NC}"
    echo -e "${DIM}  parallel, collect results, and upload to your chosen destination.${NC}"
    echo -e "${DIM}  Each test takes ~25-30 minutes per node.${NC}"
    echo ""
    read -p "  Press any key to continue..." -n 1 -s
    echo ""
    echo ""

    select_nodes_and_auth || return 1
    select_output || return 1

    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  SUMMARY${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Nodes:${NC}     ${#NODE_IPS[@]}"
    echo -e "  ${CYAN}User:${NC}      ${SSH_USER}"
    echo -e "  ${CYAN}Key:${NC}       $(basename ${SSH_KEY})"
    echo -e "  ${CYAN}Site:${NC}      ${DC_NAME} (${ALTITUDE} ft)"
    case "${OUTPUT_MODE}" in
        local)  echo -e "  ${CYAN}Save to:${NC}   Each node → /root/TDAS/" ;;
        node)   echo -e "  ${CYAN}Save to:${NC}   ${COLLECT_NODE} → /root/Reports/thermal-results/" ;;
        gdrive) echo -e "  ${CYAN}Save to:${NC}   Google Drive → ${GDRIVE_FOLDER}/" ;;
        ftp)    echo -e "  ${CYAN}Save to:${NC}   FTP → ${FTP_HOST}:${FTP_PATH:-/thermal-results}/" ;;
    esac
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo ""
    read -p "  Ready to go? (Y/n): " lc
    [[ "$lc" =~ ^[Nn]$ ]] && { echo "Cancelled."; return 0; }

    echo ""
    log_info "Running pre-flight checks..."

    # verify we can reach all nodes
    local preflight_fail=0
    for ip in "${NODE_IPS[@]}"; do
        if ssh_cmd "$ip" "echo ok" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $ip -- SSH OK"
        else
            echo -e "  ${RED}✗${NC} $ip -- SSH failed (check key/user)"
            preflight_fail=1
        fi
    done

    [[ $preflight_fail -eq 1 ]] && { log_error "Fix SSH issues above before continuing"; return 1; }

    # verify sudo works
    local sudo_fail=0
    for ip in "${NODE_IPS[@]}"; do
        if ssh_cmd "$ip" "sudo whoami" 2>/dev/null | grep -q root; then
            echo -e "  ${GREEN}✓${NC} $ip -- sudo OK"
        else
            echo -e "  ${RED}✗${NC} $ip -- sudo failed (needs passwordless sudo)"
            sudo_fail=1
        fi
    done

    [[ $sudo_fail -eq 1 ]] && { log_error "Fix sudo issues above before continuing"; return 1; }

    # verify output destination works
    case "${OUTPUT_MODE}" in
        node)
            echo -e "\n  ${CYAN}Testing result delivery path...${NC}"

            # can we reach the collection node?
            if ! ssh_cmd "$COLLECT_NODE" "echo ok" >/dev/null 2>&1; then
                log_error "Cannot SSH to collection node $COLLECT_NODE"
                return 1
            fi

            # can collection node create the reports dir?
            ssh_cmd "$COLLECT_NODE" "sudo mkdir -p /root/Reports/thermal-results && sudo touch /root/Reports/thermal-results/.preflight-test && sudo rm /root/Reports/thermal-results/.preflight-test"
            if [[ $? -ne 0 ]]; then
                log_error "Cannot write to /root/Reports/thermal-results/ on $COLLECT_NODE"
                return 1
            fi
            echo -e "  ${GREEN}✓${NC} $COLLECT_NODE -- write path OK"

            # push temp key and test SCP from collection node to each worker
            ssh_cmd "$COLLECT_NODE" "sudo mkdir -p /root/.thermal-key"
            scp_to "$COLLECT_NODE" "$SSH_KEY" "/tmp/.thermal-preflight-key"
            ssh_cmd "$COLLECT_NODE" "sudo mv /tmp/.thermal-preflight-key /root/.thermal-key/id && sudo chmod 600 /root/.thermal-key/id"

            for ip in "${NODE_IPS[@]}"; do
                [[ "$ip" == "$COLLECT_NODE" ]] && continue
                # resolve internal IP for node-to-node SCP
                local worker_internal
                worker_internal=$(ssh_cmd "$ip" "hostname -I | awk '{print \$1}'" | tr -d '\r')
                # create a test file on worker, try to pull it via internal IP
                ssh_cmd "$ip" "echo preflight > /tmp/.thermal-preflight-test" </dev/null
                ssh_cmd "$COLLECT_NODE" "sudo scp -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i /root/.thermal-key/id ${SSH_USER}@${worker_internal}:/tmp/.thermal-preflight-test /tmp/.thermal-preflight-verify" </dev/null 2>/dev/null
                local verify
                verify=$(ssh_cmd "$COLLECT_NODE" "cat /tmp/.thermal-preflight-verify 2>/dev/null" | tr -d '\r')
                ssh_cmd "$ip" "rm -f /tmp/.thermal-preflight-test" </dev/null
                ssh_cmd "$COLLECT_NODE" "rm -f /tmp/.thermal-preflight-verify" </dev/null

                if [[ "$verify" == "preflight" ]]; then
                    echo -e "  ${GREEN}✓${NC} $COLLECT_NODE → $ip (${worker_internal}) -- SCP OK"
                else
                    log_error "$COLLECT_NODE cannot SCP from $ip (${worker_internal}) -- check SSH key access"
                    ssh_cmd "$COLLECT_NODE" "sudo rm -rf /root/.thermal-key"
                    return 1
                fi
            done

            ssh_cmd "$COLLECT_NODE" "sudo rm -rf /root/.thermal-key"
            echo -e "  ${GREEN}✓${NC} All delivery paths verified"
            ;;
        gdrive)
            echo -e "\n  ${CYAN}Testing Google Drive access from ${NODE_IPS[0]}...${NC}"
            # install rclone temporarily for test, push key, test listing
            local gtest_node="${NODE_IPS[0]}"
            local has_rc
            has_rc=$(ssh_cmd "$gtest_node" "which rclone 2>/dev/null")
            if [[ -z "$has_rc" ]]; then
                ssh_cmd "$gtest_node" "curl -s https://rclone.org/install.sh | sudo bash" >/dev/null
            fi
            push_gdrive_sa_key "$gtest_node"
            local gtest
            gtest=$(ssh_cmd "$gtest_node" "sudo rclone lsd ':drive:' \
                --drive-service-account-file /tmp/.gdrive-sa.json \
                --drive-team-drive '${GDRIVE_TEAM_DRIVE}' \
                --drive-scope drive 2>&1" | head -3)
            ssh_cmd "$gtest_node" "sudo rm -f /tmp/.gdrive-sa.json"
            [[ -z "$has_rc" ]] && ssh_cmd "$gtest_node" "sudo rm -f /usr/bin/rclone /usr/local/bin/rclone" 2>/dev/null

            if [[ $? -eq 0 ]] && ! echo "$gtest" | grep -qi "error\|failed\|denied"; then
                echo -e "  ${GREEN}✓${NC} Google Drive accessible from ${gtest_node}"
            else
                log_error "Cannot access Google Drive from ${gtest_node}"
                echo -e "     ${DIM}${gtest}${NC}"
                return 1
            fi
            ;;
        ftp)
            echo -e "\n  ${CYAN}Testing FTP connection...${NC}"
            local ftp_test
            ftp_test=$(curl -s --connect-timeout 5 -u "${FTP_USER:-anonymous}:${FTP_PASS:-}" "ftp://${FTP_HOST}/" 2>&1)
            if [[ $? -eq 0 ]]; then
                echo -e "  ${GREEN}✓${NC} FTP connection OK"
            else
                log_error "Cannot connect to FTP: ${FTP_HOST}"
                return 1
            fi
            ;;
    esac

    echo ""
    log_success "Pre-flight passed"
    echo -e "\n${GREEN}${BOLD}>>> LAUNCHING -- no more prompts, sit back <<<${NC}\n"
    check_pssh || return 1
    save_history
    deploy_and_run
}

# ─── CLI Mode ─────────────────────────────────────────────────

show_help() {
    echo -e "\n${BOLD}GPU Thermal Diagnostics - PSSH Manager v${SCRIPT_VERSION}${NC}"
    echo -e "${DIM}Runs thermal diagnostics on bare-metal nodes via parallel-ssh${NC}\n"
    echo "USAGE:  $SCRIPT_NAME                       Interactive menu"
    echo "        $SCRIPT_NAME run [OPTIONS]          Launch diagnostics"
    echo ""
    echo "RUN OPTIONS:"
    echo "  --nodes \"ip1 ip2\"         Target node IPs"
    echo "  --nodes-file FILE         Load IPs from file"
    echo "  --user USER               SSH username"
    echo "  --key PATH                SSH private key path"
    echo "  --output MODE             local|node|gdrive|ftp"
    echo "  --collect-node IP         Collection node (node mode)"
    echo "  --gdrive-folder NAME      Google Drive folder (gdrive mode)"
    echo "  --ftp-host HOST           FTP host (ftp mode)"
    echo "  --ftp-user USER           FTP user"
    echo "  --ftp-pass PASS           FTP password"
    echo ""
    echo "EXAMPLES:"
    echo "  $SCRIPT_NAME run --user root --key ~/.ssh/id_rsa --nodes \"10.0.1.50 10.0.1.51\" --output local"
    echo "  $SCRIPT_NAME run --user admin --key ~/keys/gpu.pem --nodes-file fleet.txt --output node --collect-node 10.0.1.50"
    echo ""
}

parse_cli_args() {
    local cmd="${1:-}"; shift 2>/dev/null || true
    case "$cmd" in
        run)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --nodes) NODE_IPS=($(echo "$2" | tr ',' ' ')); shift 2 ;;
                    --nodes-file) NODE_IPS=($(grep -v '^#' "$2" | grep -v '^$' | tr -s ' ')); shift 2 ;;
                    --user) SSH_USER="$2"; shift 2 ;;
                    --key) SSH_KEY="${2/#\~/$HOME}"; shift 2 ;;
                    --output) OUTPUT_MODE="$2"; shift 2 ;;
                    --collect-node) COLLECT_NODE="$2"; shift 2 ;;
                    --gdrive-folder) GDRIVE_FOLDER="$2"; shift 2 ;;
                    --ftp-host) FTP_HOST="$2"; export FTP_HOST; shift 2 ;;
                    --ftp-user) FTP_USER="$2"; export FTP_USER; shift 2 ;;
                    --ftp-pass) FTP_PASS="$2"; export FTP_PASS; shift 2 ;;
                    *) log_error "Unknown: $1"; show_help; exit 1 ;;
                esac
            done
            [[ ${#NODE_IPS[@]} -eq 0 ]] && { log_error "No nodes. Use --nodes or --nodes-file"; exit 1; }
            [[ -z "$SSH_USER" ]] && { log_error "SSH user required (--user)"; exit 1; }
            [[ -z "$SSH_KEY" ]] && { log_error "SSH key required (--key)"; exit 1; }
            [[ ! -f "$SSH_KEY" ]] && { log_error "Key not found: $SSH_KEY"; exit 1; }
            check_pssh || exit 1
            deploy_and_run ;;
        --help|-h|help) show_help ;;
        --version|-v) echo "v${SCRIPT_VERSION}" ;;
        *) return 1 ;;
    esac
    return 0
}

# ─── Shell Alias ──────────────────────────────────────────────

create_script_alias() {
    local sp; sp="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local da="thermalpssh" zp="$HOME/.zshrc"
    read -p "Alias name [$da]: " an; an="${an:-$da}"
    cp "$zp" "${zp}.bak.$(date +%s)" 2>/dev/null
    echo "alias ${an}='bash ${sp}'" >> "$zp"
    log_success "Alias '${an}' added. Run: source ~/.zshrc"
}

# ─── Main Menu ────────────────────────────────────────────────

show_menu() {
    clear
    echo -e "\n${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║  GPU Thermal Diagnostics - PSSH Manager                 ║${NC}"
    echo -e "${BLUE}${BOLD}║  Version ${SCRIPT_VERSION}                                          ║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n  ${GREEN}${BOLD}1)${NC} Run Thermal Diagnostics  ${DIM}← start here${NC}"
    echo -e "     ${DIM}Quick wizard → auto runs across entire fleet via pssh${NC}"

    # show rerun option if history exists
    if [[ -f "$HISTORY_FILE" ]]; then
        source "$HISTORY_FILE" 2>/dev/null
        local node_count=$(echo "$NODE_IPS_STR" | wc -w | tr -d ' ')
        echo -e "\n  ${GREEN}${BOLD}2)${NC} Rerun Last  ${DIM}(${node_count} nodes as ${SSH_USER}, ${TIMESTAMP:-unknown})${NC}"
    fi

    echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}a)${NC} Shell alias  ${YELLOW}h)${NC} Help  ${RED}0)${NC} Exit"
    echo -e "${DIM}──────────────────────────────────────────────────────────${NC}\n"
}

rerun_last() {
    if ! load_history; then
        log_error "No previous run found"
        return 1
    fi
    echo ""
    echo -e "${CYAN}${BOLD}Rerunning last configuration:${NC}"
    echo -e "  ${CYAN}User:${NC}      ${SSH_USER}"
    echo -e "  ${CYAN}Key:${NC}       $(basename "$SSH_KEY")"
    echo -e "  ${CYAN}Nodes:${NC}     ${#NODE_IPS[@]} (${NODE_IPS[*]})"
    echo -e "  ${CYAN}Output:${NC}    ${OUTPUT_MODE}"
    [[ "$OUTPUT_MODE" == "node" ]] && echo -e "  ${CYAN}Collect:${NC}   ${COLLECT_NODE}"
    echo -e "  ${CYAN}Last run:${NC}  ${TIMESTAMP}"
    echo ""
    read -p "  Go? (Y/n): " rc
    [[ "$rc" =~ ^[Nn]$ ]] && return 0
    echo -e "\n${GREEN}${BOLD}>>> LAUNCHING -- no more prompts, sit back <<<${NC}\n"
    check_pssh || return 1
    deploy_and_run
}

run_menu() {
    while true; do
        show_menu; read -p "  Select: " ch
        case "$ch" in
            1) run_diagnostics_menu ;;
            2) rerun_last ;;
            a|A) create_script_alias ;; h|H) show_help ;; 0|q|Q) exit 0 ;;
            *) echo -e "  ${RED}Invalid${NC}" ;;
        esac
        echo ""; read -p "Press Enter..." _
    done
}

# ─── Entry Point ──────────────────────────────────────────────

[[ ! -f "$THERMAL_SCRIPT" ]] && { log_error "Thermal script not found: $THERMAL_SCRIPT"; exit 1; }

if [[ $# -gt 0 ]]; then parse_cli_args "$@" || run_menu; else run_menu; fi
