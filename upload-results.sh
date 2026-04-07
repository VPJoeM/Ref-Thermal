#!/usr/bin/env bash
# upload-results.sh - Upload thermal result zips to Google Drive
# Usage: bash upload-results.sh /path/to/dc-folder/
# Folder should contain: hostname-ServiceTag.zip files
# Folder name is used as DC identifier (e.g. sea1, iad1, dfw1)

SCRIPT_VERSION="1.1.0"
GDRIVE_TEAM_DRIVE="0AEnvoKAUzsPmUk9PVA"
GDRIVE_BASE_FOLDER="thermal-results"
GDRIVE_PASS_FILE="/tmp/.thermal-gdrive-pass"
GDRIVE_SA_ENC="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"
GDRIVE_PASS=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

usage() {
    echo -e "\n${BOLD}Thermal Results Uploader v${SCRIPT_VERSION}${NC}\n"
    echo "Uploads individual hostname-ServiceTag.zip files to Google Drive."
    echo ""
    echo "Usage:  $0 /path/to/folder/"
    echo ""
    echo "  The folder name is used as the DC identifier."
    echo "  Files must be named: hostname-ServiceTag.zip"
    echo ""
    echo "Example:"
    echo "  $0 /data/thermal-results/sea1/"
    echo "  $0 /data/thermal-results/iad1/"
    echo ""
    echo "Google Drive destination:"
    echo "  thermal-results/<dc-name>/hostname-ServiceTag.zip"
    echo ""
    exit 0
}

[[ "$1" == "--help" || "$1" == "-h" ]] && usage
[[ -z "$1" ]] && { log_error "No directory specified."; usage; }
[[ ! -d "$1" ]] && { log_error "Directory not found: $1"; exit 1; }

RESULTS_DIR="${1%/}"
DC_NAME=$(basename "$RESULTS_DIR")

# load/prompt for password
[[ -f "$GDRIVE_PASS_FILE" ]] && GDRIVE_PASS=$(cat "$GDRIVE_PASS_FILE" 2>/dev/null)
if [[ -z "$GDRIVE_PASS" ]]; then
    echo -e "\n${CYAN}Google Drive credentials required.${NC}"
    read -sp "  Password: " GDRIVE_PASS; echo ""
    _test=$(mktemp /tmp/.gdrive-test-XXXX)
    echo "$GDRIVE_SA_ENC" | base64 -d | openssl enc -aes-256-cbc -pbkdf2 -d \
        -pass "pass:${GDRIVE_PASS}" > "$_test" 2>/dev/null
    if [[ $? -ne 0 || ! -s "$_test" ]]; then
        rm -f "$_test"; log_error "Wrong password."; exit 1
    fi
    rm -f "$_test"
    echo "$GDRIVE_PASS" > "$GDRIVE_PASS_FILE" && chmod 600 "$GDRIVE_PASS_FILE"
    log_success "Credentials verified"
fi

# decrypt SA key
SA_JSON=$(echo "$GDRIVE_SA_ENC" | base64 -d | openssl enc -aes-256-cbc -pbkdf2 -d \
    -pass "pass:${GDRIVE_PASS}" 2>/dev/null)
[[ -z "$SA_JSON" ]] && { log_error "Failed to decrypt credentials."; exit 1; }

# install rclone if needed
if ! command -v rclone &>/dev/null; then
    log_info "Installing rclone..."
    curl -s https://rclone.org/install.sh | bash >/dev/null 2>&1 || {
        log_error "Failed to install rclone. Install manually: https://rclone.org"
        exit 1
    }
fi

# write SA key to temp file
SA_FILE=$(mktemp /tmp/.gdrive-sa-XXXX.json)
echo "$SA_JSON" > "$SA_FILE"
chmod 600 "$SA_FILE"
trap "rm -f '$SA_FILE'" EXIT

# find zip files
mapfile -t ZIPS < <(find "$RESULTS_DIR" -maxdepth 1 -name "*.zip" | sort)
TOTAL=${#ZIPS[@]}

[[ $TOTAL -eq 0 ]] && { log_error "No .zip files found in $RESULTS_DIR"; exit 1; }

DRIVE_FOLDER="${GDRIVE_BASE_FOLDER}/${DC_NAME}"

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Thermal Results Uploader${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "  ${CYAN}Source:${NC}      ${RESULTS_DIR}/"
echo -e "  ${CYAN}DC:${NC}          ${DC_NAME}"
echo -e "  ${CYAN}Files:${NC}       ${TOTAL} zip files"
echo -e "  ${CYAN}Destination:${NC} Google Drive → ${DRIVE_FOLDER}/"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

# validate file names look correct (hostname-ServiceTag.zip)
bad_names=0
for z in "${ZIPS[@]}"; do
    bn=$(basename "$z")
    if [[ ! "$bn" =~ ^[a-z0-9]+-[A-Z0-9]+\.zip$ ]]; then
        log_warn "Unexpected filename format: $bn (expected hostname-ServiceTag.zip)"
        bad_names=$((bad_names + 1))
    fi
done
[[ $bad_names -gt 0 ]] && echo ""

# check for tensor_active results in each zip (GPU stress test output)
echo -e "${CYAN}Validating GPU stress test results (tensor_active)...${NC}"
missing_tensor=()
has_tensor=()

for z in "${ZIPS[@]}"; do
    bn=$(basename "$z")
    # check if zip contains tensor_active files
    if unzip -l "$z" 2>/dev/null | grep -q "tensor_active"; then
        has_tensor+=("$z")
    else
        missing_tensor+=("$bn")
    fi
done

echo -e "  ${GREEN}✓${NC} ${#has_tensor[@]} files have tensor_active results"

if [[ ${#missing_tensor[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}WARNING: ${#missing_tensor[@]} files MISSING tensor_active results:${NC}"
    echo -e "${DIM}These zips may have incomplete GPU stress tests (dcgmproftester failed)${NC}"
    echo ""
    for mf in "${missing_tensor[@]}"; do
        echo -e "  ${RED}✗${NC} $mf"
    done
    echo ""
    echo -e "${YELLOW}Possible causes:${NC}"
    echo -e "  - DCGM version mismatch (check dcgmproftester.log in zip)"
    echo -e "  - GPU was busy during test"
    echo -e "  - Test was interrupted"
    echo ""
    read -rp "Upload files WITH tensor_active only? [Y/n]: " skip_bad
    if [[ ! "$skip_bad" =~ ^[Nn]$ ]]; then
        ZIPS=("${has_tensor[@]}")
        TOTAL=${#ZIPS[@]}
        log_info "Uploading ${TOTAL} validated files only"
    else
        log_warn "Uploading ALL files including those without tensor_active"
    fi
    echo ""
fi

[[ $TOTAL -eq 0 ]] && { log_error "No valid files to upload"; exit 1; }

uploaded=0; failed=0

for z in "${ZIPS[@]}"; do
    bn=$(basename "$z")
    sz=$(du -h "$z" | cut -f1)
    echo -ne "  ${YELLOW}→${NC} ${bn} (${sz})..."

    rclone copyto "$z" ":drive:${DRIVE_FOLDER}/${bn}" \
        --drive-service-account-file "$SA_FILE" \
        --drive-team-drive "$GDRIVE_TEAM_DRIVE" \
        --drive-scope drive \
        --progress=false \
        2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo -e " ${GREEN}✓${NC}"
        uploaded=$((uploaded + 1))
    else
        echo -e " ${RED}✗ failed${NC}"
        failed=$((failed + 1))
    fi
done

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
if [[ $uploaded -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}  UPLOAD COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Uploaded:${NC}    ${uploaded}/${TOTAL} files"
    echo -e "  ${CYAN}Location:${NC}    ${DRIVE_FOLDER}/"
fi
[[ $failed -gt 0 ]] && echo -e "  ${RED}Failed:${NC}      ${failed} files"
[[ ${#missing_tensor[@]} -gt 0 ]] && echo -e "  ${YELLOW}Skipped:${NC}     ${#missing_tensor[@]} files (missing tensor_active)"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""
