#!/bin/bash
# Container entrypoint for GPU thermal diagnostics
# Wraps the existing script for K8s pod execution

set -euo pipefail

export NON_INTERACTIVE=true
export AUTO_STOP_SERVICES=false
export AUTO_KILL_GPU_PROCESSES=true

SCRIPT_PATH="/opt/thermal-diagnostics/thermal-diagnostics.sh"
RESULTS_BASE="/root/TDAS"

# Create nsenter wrappers for host tools that can't run inside a container
# racadm and ipmitool need direct hardware access through the host
for tool in racadm ipmitool; do
    cat > /usr/local/bin/${tool} << 'WRAPPER'
#!/bin/bash
exec nsenter -t 1 -m -u -i -n -- TOOL_NAME "$@"
WRAPPER
    sed -i "s|TOOL_NAME|${tool}|" /usr/local/bin/${tool}
    chmod +x /usr/local/bin/${tool}
done

# Patch the script to skip package installation (tools available via nsenter wrappers)
# and skip container service checks since we're inside K8s
sed -i 's/check_packages$/check_packages || true/' "$SCRIPT_PATH"

# Skip the package install function entirely -- replace it with a check-only version
sed -i '/^check_packages()/,/^}/c\
check_packages() {\
    display_message "INFO" "Container mode: using host tools via nsenter"\
    # verify we can reach host tools\
    for cmd in racadm ipmitool nvidia-smi dcgmi bc zip; do\
        if command -v "$cmd" \&>/dev/null; then\
            display_message "INFO" "  ✓ $cmd available"\
        else\
            display_message "WARNING" "  ✗ $cmd not found"\
        fi\
    done\
    # start nv-hostengine for dcgm if not running\
    nv-hostengine -d 2>/dev/null || true\
    return 0\
}' "$SCRIPT_PATH"

# Patch the service check to skip kubelet/containerd checks
sed -i '/# --- Check for container\/kubernetes services ---/,/^    return 0$/c\
    # container mode: skip k8s service checks\
    display_message "INFO" "Container mode: skipping container/Kubernetes service checks"\
    return 0' "$SCRIPT_PATH"

echo "============================================"
echo "  GPU Thermal Diagnostics - Container Mode"
echo "============================================"
echo "  Output Mode:   ${OUTPUT_MODE:-local}"
echo "  Altitude:      ${altitude_ft:-not set}"
echo "  DC Name:       ${DC_NAME:-thermal-run}"
echo "============================================"

# run the thermal test
bash "$SCRIPT_PATH" --local
TEST_EXIT=$?

echo "Thermal test completed with exit code: $TEST_EXIT"

# find the results zip created by this run (only zips newer than script start)
RESULTS_ZIP=$(find "$RESULTS_BASE" -maxdepth 1 -name "dcgmprof-*.zip" -type f -newer /proc/$$/cmdline 2>/dev/null | head -1)

# fallback: newest zip by timestamp
if [[ -z "$RESULTS_ZIP" ]]; then
    RESULTS_ZIP=$(ls -t "$RESULTS_BASE"/dcgmprof-*.zip 2>/dev/null | head -1)
fi

# last resort: zip any unzipped dcgmprof directory from this run
if [[ -z "$RESULTS_ZIP" ]]; then
    RESULTS_DIR=$(ls -td "$RESULTS_BASE"/dcgmprof-*/ 2>/dev/null | head -1)
    if [[ -n "$RESULTS_DIR" && -d "$RESULTS_DIR" ]]; then
        echo "Zipping results directory..."
        cd "$RESULTS_BASE"
        zip -r "${RESULTS_DIR%/}.zip" "$(basename "${RESULTS_DIR%/}")" >/dev/null 2>&1
        RESULTS_ZIP="${RESULTS_DIR%/}.zip"
    fi
fi

if [[ -z "$RESULTS_ZIP" || ! -f "$RESULTS_ZIP" ]]; then
    echo "ERROR: No results found in $RESULTS_BASE"
    exit 1
fi

echo "Results zip: $RESULTS_ZIP ($(du -h "$RESULTS_ZIP" | cut -f1))"

# extract service tag from zip filename: dcgmprof-{SVCTAG}-{hostname}-...
HOSTNAME_SHORT=$(hostname -s)
ZIP_BASE=$(basename "$RESULTS_ZIP")
SERVICE_TAG=$(echo "$ZIP_BASE" | sed -E 's/^dcgmprof-([^-]+)-.*/\1/')
[[ "$SERVICE_TAG" == "$ZIP_BASE" ]] && SERVICE_TAG="UNKNOWN"
[[ -z "$SERVICE_TAG" ]] && SERVICE_TAG="UNKNOWN"

# the collect_and_rollup function picks up dcgmprof-*.zip directly from TDAS
# no need to copy -- the hostPath mount means it's already on the host
echo "Results ready for collection: ${HOSTNAME_SHORT}-${SERVICE_TAG} ($(du -h "$RESULTS_ZIP" | cut -f1))"

exit $TEST_EXIT
