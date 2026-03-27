#!/bin/bash

# Function to map exit codes to meaningful error messages
get_error_message() {
    local code=$1
    case $code in
        1) echo "General error - Script encountered an unexpected issue" ;;
        2) echo "Required package installation failed" ;;
        3) echo "DCGM service could not be started" ;;
        4) echo "Failed to set up credentials or access racadm" ;;
        5) echo "Failed to collect critical TSR data" ;;
        6) echo "GPU thermal test failed to complete" ;;
        7) echo "Failed to generate temperature summary" ;;
        8) echo "User interrupted the script execution" ;;
        9) echo "Cannot clear existing TSR jobs - Jobs are currently running" ;;
        10) echo "Running GPU processes detected - Test aborted" ;;
        11) echo "Running container services (kube/containerd/docker) detected - Test aborted" ;;
        17) echo "SupportAssist Collection Operation failed unexpectedly" ;;
        126) echo "Permission denied or command not executable" ;;
        127) echo "Command not found" ;;
        130) echo "Script terminated by Ctrl+C" ;;
        137) echo "Script received kill signal" ;;
        *) echo "Unknown error code: $code" ;;
    esac
}

# Function to display formatted messages (Define early as it might be used by other early functions)
display_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        INFO)
            echo -e "\e[32m[INFO]\e[0m $timestamp: $message"
            ;;
        WARNING)
            echo -e "\e[33m[WARNING]\e[0m $timestamp: $message"
            ;;
        ERROR)
            echo -e "\e[31m[ERROR]\e[0m $timestamp: $message"
            ;;
        SUCCESS)
            echo -e "\e[32m[SUCCESS]\e[0m $timestamp: $message"
            ;;
        *)
            echo "$timestamp: $message"
            ;;
    esac
}

# Function to update context file (Define early for handle_exit)
update_context_file() {
    local action="$1"
    local result="$2"
    local context_file="${LOGDIR_BASE}/thermal_context.md"
    
    # Ensure LOGDIR_BASE is set, otherwise we can't write the file
    if [ -z "${LOGDIR_BASE}" ]; then
        # Maybe print to stderr? But avoid calling display_message which might not be defined yet
        # Or just silently fail? For now, let's just return if LOGDIR_BASE is unset.
        return 1
    fi

    # Create directory if it doesn't exist (needed if this runs very early)
    mkdir -p "${LOGDIR_BASE}" 2>/dev/null

    # Create file with header if it doesn't exist
    if [ ! -f "$context_file" ]; then
        echo "# Thermal Diagnostics Test Context" > "$context_file" # Use > to overwrite/create
        # Check if hostname command is available
        local hn="unknown-host"
        command -v hostname &>/dev/null && hn=$(hostname)
        echo "## Running on: $hn" >> "$context_file"
        echo "## Started: $(date)" >> "$context_file"
        echo "## Actions and Results:" >> "$context_file"
    fi
    
    # Add the new context entry
    echo "### $(date): $action" >> "$context_file"
    echo "$result" >> "$context_file"
    echo "" >> "$context_file"
}

# Function to handle script exit
handle_exit() {
    local exit_code=$?
    
    # Skip heavy exit handling for early exits (--help, --version, multi-node mode)
    if [[ -z "${LOGDIR:-}" ]] || [[ "${MULTI_NODE_MODE:-}" == "true" ]]; then
        # Just cleanup any background PIDs silently and exit
        kill_background_pids "quiet" 2>/dev/null || true
        return
    fi
    
    local custom_message=""
    local marker_file="${LOGDIR}/test_completion_marker"
    local code_file="${LOGDIR}/final_exit_code"
    
    # Ensure background PIDs are terminated
    kill_background_pids
    
    # Check for stored path to results (may be zip file)
    local results_path="${LOGDIR}"
    if [ -f "${LOGDIR_BASE}/last_results_path" ]; then
        results_path=$(cat "${LOGDIR_BASE}/last_results_path")
    elif [ -f "${LOGDIR}.zip" ] && [ ! -d "${LOGDIR}" ]; then
        # If marker not found but zip exists, assume that's our results
        results_path="${LOGDIR}.zip"
    fi

    # If an explicit code was passed (e.g., by calling 'exit N')
    if [ $# -ge 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        exit_code=$1
        shift
    fi

    # If a custom message was passed
    if [ $# -ge 1 ]; then
        custom_message="$1"
    fi

    # Override with stored final code if marker exists
    if [ -f "$marker_file" ] && [ -f "$code_file" ]; then
        stored_code=$(cat "$code_file" 2>/dev/null || echo $exit_code) # Read stored code or keep current
        # Only override if stored code is non-zero (indicates failure/warning)
        if [[ "$stored_code" =~ ^[1-9][0-9]*$ ]]; then 
            exit_code=$stored_code # Use the specific code we stored (e.g., 1 for thermal fail, 7 for processing fail)
        elif [ -f "$code_file" ] && [ "$(cat "$code_file")" == "0" ] && [ $exit_code -ne 0 ]; then
             # If stored code was 0, but we are exiting non-zero now, it means an error happened *after* check_failures
             # Keep the current non-zero exit_code in this specific scenario
             : # No-op, exit_code remains the current non-zero value
        fi
    fi

    # Retrieve Service Tag using the improved method
    local service_tag=$(get_service_tag)

    # Log the retrieved Service Tag to context
    update_context_file "System Info" "Retrieved Service Tag (Asset Tag): ${service_tag}"

    if [ $exit_code -ne 0 ]; then
        # Check if the core test completed (marker exists)
        if [ -f "$marker_file" ]; then
            local final_status_msg=""
            local error_msg=$(get_error_message $exit_code) # Get generic message as a fallback
            
            # Determine status based on the final exit code
            if [ $exit_code -eq 7 ]; then # Processing failure
                final_status_msg="Thermal diagnostics completed with **PROCESSING ERRORS** (Code: $exit_code)"
                error_msg="Errors encountered during data processing. Check logs."
            else # Other non-zero codes indicate script errors/warnings
                 final_status_msg="Thermal diagnostics completed with **SCRIPT WARNINGS/ERRORS** (Code: $exit_code)"
                 if [ -n "$custom_message" ]; then error_msg="$custom_message"; fi
            fi
            
            echo "Script finished: $final_status_msg" # This goes to stdout
            
            # NOTE: test_summary.txt removed - Dell v2.6 no longer provides pass/fail interpretation

            # Display Service Tag info to terminal
            display_message "INFO" "System Service Tag (Asset Tag): ${service_tag}"
            if [ "$service_tag" != "N/A" ] && [ "$service_tag" != "N/A (racadm not found)" ]; then
                 display_message "INFO" "==> Please include this Service Tag in any support case with Dell <=="
            fi
            display_message "INFO" "==> Submit results to Dell for thermal analysis and RMA determination <=="
            
            # Check if the summary should be displayed from the original or archived location
            if [ -f "$summary_file" ]; then
                echo "Detailed test summary written to $summary_file (in ${results_path})"
            else
                # If directory is gone (zipped), suggest looking in the archive
                echo "Detailed test summary available in ${results_path}"
            fi

            # Skip failed GPU summary - failure detection removed (v2.6 alignment)
            if false && [ -f "${LOGDIR}/faillog.log" ]; then  # Disabled - kept for reference
                local fail_log="${LOGDIR}/faillog.log"
                local host=$(hostname)
                local failed_serials=()
                local failed_gpu_details=()
                local failed_count=0

                # Extract unique serial numbers (assuming serial is column 4 in faillog.log)
                failed_serials=($(tail -n +2 "$fail_log" | cut -d ',' -f 4 | tr -d ' ' | sort -u))
                failed_count=${#failed_serials[@]}

                if [ $failed_count -gt 0 ]; then
                    # --- BEGIN racadm modification ---
                    display_message "WARNING" "Querying racadm hardware inventory for physical slot IDs of failed GPUs..."
                    local racadm_inventory_output
                    # --- CHANGE: Use broader hwinventory command ---
                    racadm_inventory_output=$(racadm hwinventory 2>&1) # Capture stdout and stderr 
                    # --- END CHANGE ---
                    local racadm_status=$?

                    if [ $racadm_status -ne 0 ] || [[ "$racadm_inventory_output" == *"ERROR:"* ]]; then
                        display_message "ERROR" "Failed to get hardware inventory from racadm (Status: $racadm_status). Cannot determine physical slots. Output: $racadm_inventory_output"
                        update_context_file "racadm Error" "Failed racadm hwinventory command (Status: $racadm_status)."
                        # Set output to empty so the loop defaults to "racadm failed"
                        racadm_inventory_output=""
                    elif [ -z "$racadm_inventory_output" ]; then
                         display_message "WARNING" "racadm hardware inventory output was empty. Cannot determine physical slots."
                         update_context_file "racadm Warning" "racadm hwinventory output was empty."
                    else
                         display_message "INFO" "Successfully retrieved racadm hardware inventory."
                    fi
                    # --- END racadm fetch ---

                    for serial in "${failed_serials[@]}"; do
                        # --- BEGIN racadm parsing ---
                        local physical_slot="Not Found" # Default value

                        if [ -n "$racadm_inventory_output" ]; then
                            # --- NEW Parsing Logic --- 
                            # Find the line number containing the serial number
                            local serial_line_num=$(echo "$racadm_inventory_output" | grep -n "SerialNumber = $serial" | head -n 1 | cut -d: -f1)
                            
                            if [ -n "$serial_line_num" ]; then
                                # Found the serial line. Now find the InstanceID line *before* it.
                                # Use tac to reverse, find the first Video.Slot InstanceID above the serial line, then tac back.
                                local instance_id_line=$(echo "$racadm_inventory_output" | head -n "$serial_line_num" | tac | grep -m 1 '\[InstanceID: Video\.Slot\.' | tac)
                                
                                if [ -n "$instance_id_line" ]; then
                                    # Extract the slot number using Perl-compatible regex (requires grep -P)
                                    # Matches digits between "Video.Slot." and the following "-"
                                    physical_slot=$(echo "$instance_id_line" | grep -oP 'Video\.Slot\.\K[0-9]+(?=-)')
                                    if [ -z "$physical_slot" ]; then
                                         physical_slot="Parse Error" # Regex failed
                                    fi
                                else
                                    physical_slot="ID Line Error" # Couldn't find InstanceID line before serial
                                fi
                            else
                                physical_slot="Serial Error" # Serial number itself wasn't found
                            fi
                            # --- END NEW Parsing Logic ---
                        else
                             physical_slot="racadm N/A" # Indicate racadm command failed or gave no output
                        fi
                        # --- END racadm parsing ---
                        
                        # --- REMOVED nvidia-smi query ---
                        # local pci_id=$(nvidia-smi --query-gpu=serial,pci.bus_id --format=csv,noheader,nounits | grep "$serial" | cut -d ',' -f 2 | tr -d ' ')
                        # if [ -z "$pci_id" ]; then
                        #     pci_id="Not Found"
                        # fi
                        # failed_gpu_details+=("  * Failed GPU on $host Serial: $serial Slot ID: $pci_id")
                        # --- END REMOVED nvidia-smi query ---
                        
                        # Add detail using the physical slot found via racadm
                        failed_gpu_details+=("  * Failed GPU on $host Serial: $serial Slot ID: $physical_slot")
                    done

                    # Construct and print the final summary block to terminal only
                    echo "" # Add a blank line before the summary
                    echo -e "\\e[1;31m===========================================================\\e[0m" # Red color
                    echo -e "\\e[1;31m                FAILED GPUs REQUIRING REPLACEMENT          \\e[0m"
                    echo -e "\\e[1;31m===========================================================\\e[0m"
                    display_message "WARNING" "Identified ${failed_count} failed GPU(s) for replacement:"
                    # --- CHANGE: Use for loop instead of printf ---
                    for detail_line in "${failed_gpu_details[@]}"; do
                        echo "$detail_line"
                    done
                    # --- END CHANGE ---
                    # printf '%s\\n' "${failed_gpu_details[@]}" # Print each failed GPU detail line (OLD METHOD)
                    # --- ADDED: Ensure newline before next separator (Keep this) ---
                    echo ""
                    # --- END ADDED ---
                    echo -e "\\e[1;31m===========================================================\\e[0m"
                    echo -e "\\e[1;31mAction required: Replace the above GPU(s) identified by serial number\\e[0m"
                    echo -e "\\e[1;31m===========================================================\\e[0m"
                    echo "" # Add a blank line after the summary

                    # Update context file
                    update_context_file "FAILURE SUMMARY (Terminal)" "Detected ${failed_count} failed GPUs requiring replacement (Serials: ${failed_serials[*]}). Details printed to terminal."
                fi
            fi
            # --- END ADDED CODE ---

            # Allow script to exit with the determined code
            exit $exit_code # Exit trap with the final code
        else
            # Abnormal exit before test completion marker was created (Definitely a SCRIPT FAILURE)
            local premature_exit_msg=$(get_error_message $exit_code)
            if [ -n "$custom_message" ]; then premature_exit_msg="$custom_message"; fi
            final_status_msg="Script failed prematurely (Code: $exit_code)"
            echo "Script failed: $final_status_msg" # To stdout
            echo "Reason: $premature_exit_msg" # To stdout
            update_context_file "SCRIPT FAILURE" "Script failed prematurely: $final_status_msg. Reason: $premature_exit_msg"

            # Display Service Tag info even on premature exit
            display_message "INFO" "System Service Tag (Asset Tag): ${service_tag}"
            if [ "$service_tag" != "N/A" ] && [ "$service_tag" != "N/A (racadm not found)" ]; then
                 display_message "INFO" "==> Please include this Service Tag in any support case with Dell <=="
            fi
            # Restart services that were stopped for the test
            restart_stopped_services
            # NOTE: test_summary.txt removed - Dell v2.6 no longer provides pass/fail interpretation
            exit $exit_code # Exit trap with the failure code
        fi
    else
        # Normal successful exit (code 0)
        if [ -f "$marker_file" ] && [ -n "${LOGDIR:-}" ]; then
            # NOTE: test_summary.txt removed - Dell v2.6 no longer provides pass/fail interpretation
            # Display Service Tag info to terminal
            display_message "INFO" "System Service Tag (Asset Tag): ${service_tag}"
            if [ "$service_tag" != "N/A" ] && [ "$service_tag" != "N/A (racadm not found)" ]; then
                 display_message "INFO" "==> Please include this Service Tag in any support case with Dell <=="
            fi
            display_message "INFO" "==> Submit zipped results to Dell for thermal analysis and RMA determination <=="
            
            # Restart services that were stopped for the test
            restart_stopped_services
        fi
        exit 0 # Exit trap successfully
    fi
}

# Function to restart services that were stopped for the test
restart_stopped_services() {
    local stopped_services_file="${LOGDIR:-}/stopped_services.txt"
    
    if [[ ! -f "$stopped_services_file" ]]; then
        return 0  # No services to restart
    fi
    
    display_message "INFO" "Restarting services that were stopped for the test..."
    
    local restart_failures=0
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        display_message "INFO" "Restarting service: $service"
        if systemctl start "$service" 2>/dev/null; then
            echo "  ✓ Restarted $service"
        else
            echo "  ✗ Failed to restart $service"
            restart_failures=$((restart_failures + 1))
        fi
    done < "$stopped_services_file"
    
    # Clean up the file
    rm -f "$stopped_services_file"
    
    if [[ $restart_failures -gt 0 ]]; then
        display_message "WARNING" "Some services failed to restart. Manual intervention may be needed."
        display_message "INFO" "To restart manually: sudo systemctl start kubelet containerd docker"
    else
        display_message "SUCCESS" "All stopped services have been restarted."
    fi
    
    update_context_file "Service Restart" "Restarted services after test completion"
}

# Function to handle SIGINT (Ctrl+C)
handle_sigint() {
    echo -e "\nScript interrupted by user (Ctrl+C)"
    if [ -n "${LOGDIR_BASE:-}" ]; then
        update_context_file "USER INTERRUPT" "Script terminated by user with Ctrl+C at $(date)"
    fi
    echo "8" > "${LOGDIR}/final_exit_code" 2>/dev/null || true
    exit 130
}

# Function to handle SIGTERM
handle_sigterm() {
    echo -e "\nScript received termination signal"
    if [ -n "${LOGDIR_BASE:-}" ]; then
        update_context_file "TERMINATION SIGNAL" "Script received termination signal at $(date)"
    fi
    echo "8" > "${LOGDIR}/final_exit_code" 2>/dev/null || true
    exit 143
}

# Set trap handlers for various signals
trap handle_exit EXIT
trap handle_sigint INT
trap handle_sigterm TERM HUP

# Global variables to track PIDs
WORKLOAD_PID=""
NVIDIA_SMI_PID=""
BMC_PID=""

# Initial setup
set -euo pipefail

# Global variables
THERMAL_DURATION=900  # 15 minutes
TSR_MIDRUN_DELAY=450  # 7.5 minutes
TSR_TIMEOUT=900       # 15 minutes
REMOTE_MODE=${REMOTE_MODE:-false}
NON_INTERACTIVE=${NON_INTERACTIVE:-false}  # Set by multi-node wrapper for unattended execution
LOGDIR_BASE="/root/TDAS"
LOGDIR=""
DCGM_TARGET=1004     # Adding the target variable to match thermalresults2.sh
altitude_ft=${altitude_ft:-}       # Add altitude variable
rounded_pressure_hpa=0 # Add pressure variable

# NOTE: Root privilege check moved to entry point section
# Multi-node mode runs from local machine (no root needed locally)
# Root is only required for local execution (--local flag or menu option 1)

# Setup log directory
setup_log_directory() {
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    
    # Get service tag using racadm - this needs to be fixed to properly extract the tag
    local service_tag="UNKNOWN"
    if command -v racadm &> /dev/null; then
        # Use direct grep with "Service Tag" and proper extraction
        service_tag=$(racadm getsysinfo 2>/dev/null | grep "Service Tag" | awk -F= '{print $2}' | tr -d '[:space:]')
        if [ -z "$service_tag" ]; then
            # Fallback: Try Asset Tag with proper extraction if Service Tag is empty
            service_tag=$(racadm getsysinfo 2>/dev/null | grep "Asset Tag" | awk -F= '{print $2}' | tr -d '[:space:]')
        fi
        # Default to UNKNOWN if still empty after checking both
        [ -z "$service_tag" ] && service_tag="UNKNOWN"
    fi
    
    # Create timestamp in UTC format (separate from directory name for use in display)
    CURRENT_DATE=$(date -u +%Y-%m-%d.%Hh%Mm%Ss)
    local timestamp=$(date -u "+%y-%m-%d-%H-%M") # YY-MM-DD-HH-MM format for directory name
    
    HOSTNAME=$(hostname -s)
    LOGDIR_BASE="/root/TDAS"
    mkdir -p "${LOGDIR_BASE}"
    chmod 700 "${LOGDIR_BASE}"
    
    # Use standardized naming format: dcgmprof-{SVCTAG}-{HOSTNAME}-{YY}-{mm}-{DD}-{HH}-{MM}-UTC
    LOGDIR="${LOGDIR_BASE}/dcgmprof-${service_tag}-${HOSTNAME}-${timestamp}-UTC"
    mkdir -p "${LOGDIR}"
    chmod 700 "${LOGDIR}"
    
    # Store service tag for other functions to use
    echo "$service_tag" > "${LOGDIR}/service_tag.txt"
}

# Function to zip the log directory and delete the original
zip_log_directory() {
    display_message "INFO" "Creating final zip archive of test results..."
    
    # First check if directory was already zipped
    if [ ! -d "${LOGDIR}" ] && [ -f "${LOGDIR}.zip" ]; then
        display_message "INFO" "Log directory already archived as ${LOGDIR}.zip"
        update_context_file "Archive" "Log directory already archived - no action needed"
        return 0
    fi
    
    # Check if zip command is available
    if ! command -v zip &> /dev/null; then
        display_message "ERROR" "zip command not found. Cannot archive results."
        update_context_file "Archive Error" "Failed to archive results - zip command not found."
        return 1
    fi
    
    # Construct zip filename using the same directory name
    local zip_file="${LOGDIR}.zip"
    
    # Record original directory name for reference
    local orig_dir="${LOGDIR}"
    local dir_basename=$(basename "${LOGDIR}")
    
    # NOTE: Dell v2.6 creates these files (~13 total):
    # - thermal_results.hostname.target.duration.date.csv (main CSV)
    # - TSR_SERVICETAG_DATE.zip (SupportAssist report)
    # - dcgmproftester.log (stress test output)
    # - tensor_active_0.results through tensor_active_7.results (8 per-GPU files)
    # - dcgmprofsettings.ini (if present)
    # - hostname-date-dcgmprofrunner.txt (script log - optional)
    
    # Remove only internal VP script tracking files before zipping
    rm -f "${LOGDIR}/test_completion_marker" 2>/dev/null
    rm -f "${LOGDIR}/final_exit_code" 2>/dev/null
    rm -f "${LOGDIR}/stopped_services.txt" 2>/dev/null
    rm -f "${LOGDIR}/service_tag.txt" 2>/dev/null
    rm -f "${LOGDIR}/gpu_metrics_raw.csv" 2>/dev/null
    # Keep: thermal_results.*.csv, TSR_*.zip, dcgmproftester.log, tensor_active_*.results
    
    # Change to the parent directory to zip with relative paths
    cd "${LOGDIR_BASE}"
    
    # Create zip archive with all contents
    if zip -r "${zip_file}" "${dir_basename}" > /dev/null 2>&1; then
        display_message "SUCCESS" "Successfully created archive at ${zip_file}"
        update_context_file "Archive" "Created archive of test results at ${zip_file}"
        
        # Verify zip file exists before removing directory
        if [ -f "${zip_file}" ] && [ -s "${zip_file}" ]; then
            # Give a slight delay to ensure all file operations complete
            sleep 2
            
            # Remove the original directory
            rm -rf "${orig_dir}"
            display_message "INFO" "Removed original directory ${orig_dir}"
            update_context_file "Cleanup" "Removed original log directory after successful archiving"
            
            # Display the new location for results
            display_message "INFO" "All test results are now available in ${zip_file}"
            return 0
        else
            display_message "WARNING" "Zip file was not created or is empty. Keeping original directory."
            update_context_file "Archive Warning" "Zip file creation may have failed. Keeping original directory."
            return 1
        fi
    else
        display_message "ERROR" "Failed to create zip archive."
        update_context_file "Archive Error" "Failed to create zip archive of test results."
        return 1
    fi
}

# Function to get configuration
get_configuration() {
    echo "Starting configuration..."
    if [ $# -ne 0 ]; then
        echo "Usage: $0"
        exit 1  # General error
    fi
    REMOTE_MODE=${REMOTE_MODE:-false}
    echo "Running in local mode"
}

# Function to detect OS
detect_os() {
    echo "Detecting OS..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    else
        echo "Cannot detect OS"
        exit 2  # Required component missing
    fi
    echo "Detected OS: $OS_NAME $OS_VERSION"
}

# Function to check and install required packages
check_packages() {
    echo "Checking required packages..."
    local missing_pkgs=()
    # ipmitool still needed for inlet temp / cpu display
    # bc needed for calculations
    # racadm is now essential
    # zip needed for file compression
    local required_pkgs=('racadm' 'dcgmi' 'nvidia-smi' 'ipmitool' 'bc' 'zip') 
    
    for pkg in "${required_pkgs[@]}"; do
        if ! command -v "${pkg}" &> /dev/null; then
            missing_pkgs+=("${pkg}")
        fi
    done
    
    # REMOVED: Check if racadm is missing specifically and exit
    # if [[ " ${missing_pkgs[@]} " =~ " racadm " ]]; then
    #     display_message "ERROR" "Required command 'racadm' not found. Please install Dell OMSA or ensure racadm is in the PATH."
    #     update_context_file "Package Check Error" "racadm command not found."
    #     exit 2 # Use package error code
    # fi

    # MODIFIED: Check if any packages are missing and attempt install
    if [ ${#missing_pkgs[@]} -gt 0 ]; then 
        display_message "INFO" "Attempting to install missing packages: ${missing_pkgs[*]}" # Changed level to INFO
        update_context_file "Package Check" "Attempting to install missing packages: ${missing_pkgs[*]}"

        # MODIFIED: Install racadm if needed, using the secure GPG key method
        if [[ " ${missing_pkgs[@]} " =~ " racadm " ]]; then
            display_message "INFO" "Installing racadm (srvadmin-idracadm8)..."
            update_context_file "Package Install" "Attempting racadm installation."

            # Ensure wget and gnupg are available for the installation
            for pkg in wget gnupg; do
                if ! command -v "$pkg" &> /dev/null; then
                    display_message "INFO" "Installing dependency: '$pkg'..."
                    apt-get update >/dev/null
                    apt-get install -y "$pkg"
                    if [[ $? -ne 0 ]]; then
                        display_message "ERROR" "Failed to install dependency '$pkg'. Cannot install racadm."
                        # The final package check will handle the exit.
                    fi
                fi
            done
            
            # Set up the Dell EMC repository securely
            display_message "INFO" "Setting up Dell EMC repository for Ubuntu Jammy (22.04)..."
            mkdir -p /etc/apt/keyrings
            wget -qO- https://linux.dell.com/repo/pgp_pubkeys/0x1285491434D8786F.asc | gpg --dearmor -o /etc/apt/keyrings/dell-emc-key.gpg
            if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then
                display_message "ERROR" "Failed to download or de-armor Dell GPG key. Cannot install racadm."
                rm -f /etc/apt/keyrings/dell-emc-key.gpg
            else
                # Create the repository source file
                echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/dell-emc-key.gpg] http://linux.dell.com/repo/community/openmanage/11000/jammy jammy main" > /etc/apt/sources.list.d/linux.dell.com.sources.list
                display_message "INFO" "Updating package lists after adding Dell repo..."
                apt-get update
                
                # Attempt to install racadm
            if ! apt-get install -y srvadmin-idracadm8; then
                    display_message "ERROR" "Failed to install srvadmin-idracadm8 via apt-get."
                 update_context_file "Package Install Error" "Failed to install srvadmin-idracadm8."
            else
                    display_message "SUCCESS" "Successfully installed srvadmin-idracadm8."
                 update_context_file "Package Install" "Successfully installed srvadmin-idracadm8."
                fi
            fi
        fi

        # Install DCGM if needed
        if [[ " ${missing_pkgs[@]} " =~ " dcgmi " ]]; then
            echo "Installing DCGM..."
            # Clean up any old CUDA repo files to prevent conflicts
            display_message "INFO" "Cleaning up existing CUDA repository files to prevent conflicts..."
            rm -f /etc/apt/sources.list.d/cuda*.list
            
            # Check if NVIDIA keyring is already installed before downloading
            if ! dpkg -l | grep -q cuda-keyring; then
                display_message "INFO" "NVIDIA keyring not found, installing..."
                # Detect Ubuntu version dynamically (e.g., "2204" for Ubuntu 22.04)
                local ubuntu_ver=$(lsb_release -rs 2>/dev/null | tr -d '.')
                if [ -z "$ubuntu_ver" ]; then
                    display_message "WARNING" "Could not detect Ubuntu version, defaulting to 2204"
                    ubuntu_ver="2204"
                fi
                display_message "INFO" "Detected Ubuntu version: ${ubuntu_ver}"
                wget -O /tmp/cuda-keyring.deb "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${ubuntu_ver}/x86_64/cuda-keyring_1.1-1_all.deb"
                dpkg -i /tmp/cuda-keyring.deb
                rm -f /tmp/cuda-keyring.deb
                display_message "SUCCESS" "NVIDIA keyring installed"
            else
                display_message "INFO" "NVIDIA keyring already installed"
            fi
            
            apt-get update
            
            # Detect CUDA version and install matching DCGM v4 package
            # Use nvidia-smi header output like the manual install command
            local cuda_ver=$(nvidia-smi 2>/dev/null | sed -E -n 's/.*CUDA Version: ([0-9]+)[.].*/\1/p')
            if [ -z "$cuda_ver" ]; then
                display_message "WARNING" "Could not detect CUDA version, defaulting to CUDA 12"
                cuda_ver="12"
            fi
            display_message "INFO" "Detected CUDA version: ${cuda_ver}, installing datacenter-gpu-manager-4-cuda${cuda_ver}"
            
            # Try to install the version-specific package, fallback to generic if not available
            if apt-get install -y "datacenter-gpu-manager-4-cuda${cuda_ver}" 2>/dev/null; then
                display_message "SUCCESS" "Installed datacenter-gpu-manager-4-cuda${cuda_ver}"
            else
                display_message "WARNING" "datacenter-gpu-manager-4-cuda${cuda_ver} not available, trying datacenter-gpu-manager-4-cuda12"
                if apt-get install -y datacenter-gpu-manager-4-cuda12 2>/dev/null; then
                    display_message "SUCCESS" "Installed datacenter-gpu-manager-4-cuda12 as fallback"
                else
                    display_message "WARNING" "Falling back to generic datacenter-gpu-manager package"
                    apt-get install -y datacenter-gpu-manager
                fi
            fi
        fi
        
        # Install ipmitool if needed
        if [[ " ${missing_pkgs[@]} " =~ " ipmitool " ]]; then
            echo "Installing ipmitool..."
            apt-get install -y ipmitool
        fi

        # Install bc if needed
        if [[ " ${missing_pkgs[@]} " =~ " bc " ]]; then
            echo "Installing bc..."
            apt-get install -y bc
        fi

        # Install zip if needed
        if [[ " ${missing_pkgs[@]} " =~ " zip " ]]; then
            echo "Installing zip..."
            apt-get install -y zip
        fi

        # Re-verify after install attempt
        local failed_install=false
        for pkg in "${required_pkgs[@]}"; do # Check ALL required packages again
            if ! command -v "${pkg}" &> /dev/null; then
                display_message "ERROR" "Failed to install or find required package after attempt: ${pkg}"
                failed_install=true
            fi
        done
        if $failed_install; then
             update_context_file "Package Check Error" "Failed to install required packages."
             exit 2
        fi
    else
         echo "All required packages are installed"
    fi
    
    # Check DCGM service
    if ! systemctl is-active --quiet nvidia-dcgm; then
        echo "Starting DCGM service..."
        systemctl start nvidia-dcgm
        sleep 5
        
        # If DCGM still not active, try restarting
        if ! systemctl is-active --quiet nvidia-dcgm; then
            echo "WARNING: Failed to start DCGM service, attempting to restart..."
            systemctl restart nvidia-dcgm
            sleep 5
            
            # If still not active, ask user if they want to continue
            if ! systemctl is-active --quiet nvidia-dcgm; then
                echo "WARNING: DCGM service failed to start after restart attempt"
                echo "The DCGM service is required for thermal testing"
                read -p "Do you want to continue anyway? (y/n): " choice
                if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
                    echo "Exiting as requested"
                    exit 3  # DCGM service error
                else
                    echo "Continuing despite DCGM service failure"
                fi
            else
                echo "DCGM service successfully restarted"
            fi
        fi
    fi
    
    return 0
}

# Function to set up credentials and get altitude
setup_credentials_and_altitude() {
    echo "Setting up credentials..."
    if [[ "${REMOTE_MODE}" == "false" ]]; then
        echo "Running locally, using direct racadm commands"
        # Test racadm access
        racadm getsysinfo
        echo "Local racadm access confirmed"
    fi

    # Prompt for altitude using a menu
    if [ -z "${altitude_ft}" ]; then
        echo "Select the test site location for altitude:"
        echo "  1) FTW1 (653 ft)"
        echo "  2) STR1 (289 ft)"
        echo "  3) PYL1 (220 ft)"
        echo "  4) ALN1 (656 ft)"
        echo "  5) Custom"
        read -p "Enter your choice [1-5]: " site_choice

        case $site_choice in
            1)
                altitude_ft=653
                display_message "INFO" "Selected FTW1, altitude set to 653 ft"
                update_context_file "Altitude" "User selected FTW1 (653 ft)"
                ;;
            2)
                altitude_ft=289
                display_message "INFO" "Selected STR1, altitude set to 289 ft"
                update_context_file "Altitude" "User selected STR1 (289 ft)"
                ;;
            3)
                altitude_ft=220
                display_message "INFO" "Selected PYL1, altitude set to 220 ft"
                update_context_file "Altitude" "User selected PYL1 (220 ft)"
                ;;
            4)
                altitude_ft=656
                display_message "INFO" "Selected ALN1, altitude set to 656 ft"
                update_context_file "Altitude" "User selected ALN1 (656 ft)"
                ;;
            5)
                read -p "Enter custom altitude of the test site in feet: " altitude_ft
                # Basic validation - check if it looks like a number (integer or float)
                if ! [[ "$altitude_ft" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then # Allow negative altitudes too
                    display_message "ERROR" "Altitude must be a number."
                    update_context_file "Altitude Error" "Invalid custom altitude entered: $altitude_ft"
                    exit 4 # Use credentials/config error code
                fi
                display_message "INFO" "Using custom altitude: ${altitude_ft} ft"
                update_context_file "Altitude" "User entered custom altitude: ${altitude_ft} ft"
                ;;
            *)
                display_message "ERROR" "Invalid choice. Please enter a number between 1 and 4."
                update_context_file "Altitude Error" "Invalid menu choice: $site_choice"
                exit 4 # Use credentials/config error code
                ;;
        esac
    else
        # If altitude_ft was already set (e.g., via environment variable or config file), use it.
        # We should still validate it here.
         if ! [[ "$altitude_ft" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
             display_message "ERROR" "Pre-configured altitude ('$altitude_ft') is not a valid number."
             update_context_file "Altitude Error" "Invalid pre-configured altitude: $altitude_ft"
             exit 4
         fi
        display_message "INFO" "Using pre-configured altitude: ${altitude_ft} ft"
        update_context_file "Altitude" "Using pre-configured altitude: ${altitude_ft} ft"
    fi
}

# Function to clear existing TSR jobs
clear_existing_tsr_jobs() {
    display_message "INFO" "Checking for existing TSR jobs..."
    local existing_jobs
    existing_jobs=$(racadm jobqueue view)
    echo "$existing_jobs"
    
    # Check if there are any SupportAssist Collection jobs currently running
    if echo "$existing_jobs" | grep -q "SupportAssist Collection.*Status=Running"; then
        display_message "WARNING" "Found running TSR collection jobs that cannot be deleted"
        local running_job_id=$(echo "$existing_jobs" | grep -A1 "SupportAssist Collection.*Status=Running" | grep -o "JID_[0-9]*" | head -1)
        
        if [ -n "$running_job_id" ]; then
            display_message "INFO" "Running job ID: $running_job_id"
            # Check progress of the running job
            local job_progress=$(echo "$existing_jobs" | grep -A10 "$running_job_id" | grep "Percent Complete" | grep -o "[0-9]*" | head -1)
            if [ -n "$job_progress" ]; then
                display_message "INFO" "Current job progress: $job_progress%"
            fi
        fi
        
        display_message "WARNING" "Cannot delete running jobs. Automatically waiting for completion (up to 5 minutes)"
        local wait_start=$(date +%s)
        local wait_timeout=$((wait_start + 300))  # 5 minute timeout
        
        while true; do
            sleep 30
            local current_time=$(date +%s)
            if [ $current_time -ge $wait_timeout ]; then
                display_message "ERROR" "Timeout waiting for job completion"
                break
            fi
            
            existing_jobs=$(racadm jobqueue view)
            if ! echo "$existing_jobs" | grep -q "SupportAssist Collection.*Status=Running"; then
                display_message "SUCCESS" "Running jobs completed"
                break
            fi
            
            # Update progress
            local job_progress=$(echo "$existing_jobs" | grep -A10 "$running_job_id" | grep "Percent Complete" | grep -o "[0-9]*" | head -1)
            if [ -n "$job_progress" ]; then
                display_message "INFO" "Current job progress: $job_progress%"
            fi
        done
        
        # Try deleting again
        if echo "$existing_jobs" | grep -q "SupportAssist Collection"; then
            display_message "INFO" "Attempting to clear completed TSR jobs..."
            local delete_result=$(racadm jobqueue delete -i JID_CLEARALL 2>&1)
            
            if echo "$delete_result" | grep -q "RAC1007"; then
                display_message "ERROR" "Still cannot delete jobs: $delete_result"
                update_context_file "TSR Jobs" "Failed to clear existing TSR jobs - jobs are running"
                display_message "WARNING" "Continuing without clearing existing TSR jobs"
                update_context_file "Warning" "Continuing without clearing existing TSR jobs"
                return 1
            else
                display_message "SUCCESS" "Cleared existing TSR jobs"
                update_context_file "TSR Jobs" "Cleared existing TSR jobs"
                sleep 10
                return 0
            fi
        fi
    elif echo "$existing_jobs" | grep -q "SupportAssist Collection"; then
        display_message "INFO" "Found completed TSR collection jobs, clearing..."
        local delete_result=$(racadm jobqueue delete -i JID_CLEARALL 2>&1)
        
        if echo "$delete_result" | grep -q "RAC1007"; then
            display_message "ERROR" "Cannot delete jobs: $delete_result"
            update_context_file "TSR Jobs" "Failed to clear existing TSR jobs - jobs are running"
            display_message "WARNING" "Continuing without clearing existing TSR jobs"
            update_context_file "Warning" "Continuing without clearing existing TSR jobs"
            return 1
        else
            display_message "SUCCESS" "Cleared existing TSR jobs"
            update_context_file "TSR Jobs" "Cleared existing TSR jobs"
            sleep 10
            return 0
        fi
    else
        display_message "INFO" "No TSR collection jobs found"
        update_context_file "TSR Jobs" "No existing TSR jobs to clear"
        return 0
    fi
    
    # If we get here, we were waiting for jobs but couldn't clear them
    display_message "WARNING" "Continuing without clearing existing TSR jobs"
    update_context_file "Warning" "Continuing without clearing existing TSR jobs"
    return 1
}

# Function to get the correct dcgmproftester binary based on CUDA version (from dcgmprofrunner.sh v2.6)
# This dynamically detects the installed CUDA version and returns the appropriate binary name
# NOTE: All display_message calls redirect to stderr (&2) so they don't get captured in command substitution
get_dcgmproftester_cmd() {
    # Detect CUDA version from nvidia-smi header output (e.g., "12" or "13")
    local cuda_version=$(nvidia-smi 2>/dev/null | sed -E -n 's/.*CUDA Version: ([0-9]+)[.].*/\1/p')
    
    if [ -z "$cuda_version" ]; then
        display_message "WARNING" "Could not detect CUDA version from nvidia-smi, defaulting to 12" >&2
        update_context_file "CUDA Detection" "Could not detect CUDA version, defaulting to 12"
        cuda_version="12"
    else
        display_message "INFO" "Detected CUDA version: ${cuda_version}" >&2
        update_context_file "CUDA Detection" "Detected CUDA version ${cuda_version}"
    fi
    
    local binary_name="dcgmproftester${cuda_version}"
    
    # Verify the binary exists
    if command -v "$binary_name" &> /dev/null; then
        echo "$binary_name"
        return 0
    else
        display_message "WARNING" "Binary ${binary_name} not found, trying fallback..." >&2
        update_context_file "CUDA Detection" "Binary ${binary_name} not found, trying fallback"
        
        # Fallback: try common versions in order (13, 12, 11)
        for version in 13 12 11; do
            if command -v "dcgmproftester${version}" &> /dev/null; then
                display_message "INFO" "Found fallback binary: dcgmproftester${version}" >&2
                update_context_file "CUDA Detection" "Using fallback binary dcgmproftester${version}"
                echo "dcgmproftester${version}"
                return 0
            fi
        done
        
        # No binary found
        display_message "ERROR" "No dcgmproftester binary found (tried versions 11, 12, 13)" >&2
        update_context_file "CUDA Detection Error" "No dcgmproftester binary found"
        echo ""
        return 1
    fi
}

# Function to get the current minimum fan speed setting (from dcgmprofrunner.sh v2.6)
# Returns the current fan speed offset value
get_minimum_fan_speed() {
    local fan_speed
    fan_speed=$(racadm get system.thermalsettings.FanSpeedOffset 2>/dev/null | grep "FanSpeedOffset" | cut -d "=" -f 2 | tr -d ' ')
    
    if [ -z "$fan_speed" ]; then
        # Default to 0 if we can't read it
        display_message "WARNING" "Could not read current fan speed setting, defaulting to 0" >&2
        echo "0"
    else
        echo "$fan_speed"
    fi
}

# Global variable to store original fan speed (set before changing)
ORIGINAL_FAN_SPEED=""

# Function to check SupportAssist EULA status (from dcgmprofrunner.sh v2.6)
# Returns 0 if EULA accepted, 1 if not accepted, 2 if unable to determine
check_supportassist_eula() {
    display_message "INFO" "Checking SupportAssist EULA status..."
    
    # Check if racadm is available (should be, since we're running locally)
    if ! command -v racadm &> /dev/null; then
        display_message "WARNING" "racadm not available, skipping EULA check"
        update_context_file "EULA Check" "racadm not available, skipping EULA check"
        return 2
    fi
    
    local eula_status
    eula_status=$(racadm supportassist geteulastatus 2>/dev/null)
    
    # Check if NOT accepted first (more specific check)
    if echo "$eula_status" | grep -iq "not accepted"; then
        display_message "WARNING" "*************************************************************"
        display_message "WARNING" "The SupportAssist EULA has NOT been accepted on this iDRAC!"
        display_message "WARNING" "If the EULA is not accepted, SupportAssist Collection may fail."
        display_message "WARNING" "Please log in to iDRAC and accept the EULA before proceeding."
        display_message "WARNING" "*************************************************************"
        update_context_file "EULA Check" "SupportAssist EULA has NOT been accepted"
        return 1
    elif echo "$eula_status" | grep -iq "accepted"; then
        display_message "SUCCESS" "SupportAssist EULA has previously been accepted. Proceeding..."
        update_context_file "EULA Check" "SupportAssist EULA is accepted"
        return 0
    else
        display_message "WARNING" "*************************************************************"
        display_message "WARNING" "Unable to determine SupportAssist EULA status from racadm output."
        display_message "WARNING" "Proceed with caution."
        display_message "WARNING" "*************************************************************"
        update_context_file "EULA Check" "Unable to determine SupportAssist EULA status"
        return 2
    fi
}

# Function to calculate air pressure (from dcgmprofrunner.sh)
calculate_pressure() {
    local temp_c=$1
    local altitude_ft_calc=$2

    # Input validation - Allow negative numbers, matching the prompt validation
    if ! [[ "$temp_c" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$altitude_ft_calc" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        display_message "WARNING" "Invalid numeric input to calculate_pressure: temp_c='$temp_c', altitude_ft_calc='$altitude_ft_calc'. Using default pressure 1013 hPa."
        rounded_pressure_hpa=1013 # Default to sea level if inputs invalid
        return 1
    fi


    # Constants
    local sea_level_pressure=101325  # Pa
    local temp_lapse_rate=0.0065     # K/m
    local sea_level_temp=288.15      # K
    local gas_constant=8.31447       # J/(mol·K)
    local molar_mass_air=0.0289644   # kg/mol
    local gravity=9.80665            # m/s^2

    # Convert altitude from feet to meters
    local altitude_m=$(echo "$altitude_ft_calc * 0.3048" | bc -l)

    # Convert temperature from Celsius to Kelvin
    local temp_k=$(echo "$temp_c + 273.15" | bc -l)

    # Calculate pressure in Pascals
    # Handle potential division by zero or invalid temp_k
    if (( $(echo "$temp_k <= 0" | bc -l) )); then
        display_message "WARNING" "Invalid temperature for pressure calculation (<= 0 K). Using default pressure 1013 hPa."
        rounded_pressure_hpa=1013 # Default pressure
        return 1
    fi

    local exponent=$(echo "scale=10; (-$gravity * $molar_mass_air * $altitude_m) / ($gas_constant * $temp_k)" | bc -l)
    # Use try-catch block for bc calculation
    local pressure_pa
    pressure_pa=$(echo "scale=10; $sea_level_pressure * e($exponent)" | bc -l 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$pressure_pa" ]; then
        display_message "WARNING" "Pressure calculation failed. Using default pressure 1013 hPa."
        rounded_pressure_hpa=1013 # Default pressure
        return 1
    fi


    # Convert pressure from Pascals to hPa
    local pressure_hpa=$(echo "scale=2; $pressure_pa * 0.01" | bc -l) # FIX: Add closing quote

	# Round to 0 decimal points
    rounded_pressure_hpa=$(printf "%.0f" "$pressure_hpa")

    #echo "$rounded_pressure_hpa" # We store it in global var instead
    return 0
}

# Function to get BMC data (from dcgmprofrunner.sh, adapted for TDWDL)
bmc_getter() {
    local bmc_alt_ft=$1
    local log_dir=$2 # Pass log directory

    local timestamp_log="${log_dir}/bmctimestamp.log"
    local pressure_log="${log_dir}/bmcairpressure.log"
    local temp_log="${log_dir}/bmcinlettemp.log"
    local fan_log="${log_dir}/bmcfanPWM.log"

    # Initialize log files with headers
    echo "bmc.timestamp" > "$timestamp_log"
    echo "bmc.airpressure" > "$pressure_log"
    echo "bmc.inlet.temp" > "$temp_log"
    echo "bmc.fan.pwm" > "$fan_log"

    # Remove the warning about dynamic fan fetch
    # display_message "WARNING" "Attempting to read Fan PWM using sensor name 'Fan1'. ..."

	while true
	do
		sleep 1 &
		# Capture the process ID (PID) of the sleep command
		local SLEEP_PID=$!
		local datetime=$(date +"%Y/%m/%d %H:%M:%S.%3N")
        # Use ipmitool sensor reading for inlet temp (still needed)
		local inlettemp=$(ipmitool sensor get "Inlet Temp" 2>/dev/null | grep -i 'Sensor Reading' | awk '{print $4}')

        # Handle cases where ipmitool fails or returns non-numeric data
        if ! [[ "$inlettemp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
             inlettemp="N/A" # Mark as Not Available
             rounded_pressure_hpa="N/A" # Can't calculate pressure without temp
        else
		    calculate_pressure $inlettemp $bmc_alt_ft
        fi

        # Revert Fan PWM to hardcoded value 100
        local fanpwm="100"
        # Remove dynamic fetch logic:
        # local fanpwm=$(ipmitool sensor get "Fan1" 2>/dev/null | grep -i 'Sensor Reading' | awk '{print $4}')
        # if ! [[ "$fanpwm" =~ ^[0-9]+$ ]]; then 
        #     fanpwm="N/A"
        # fi

		# Append data to logs - loop 8 times per second like dcgmprofrunner.sh
        for i in {1..8}
        do
    		echo $datetime >> "$timestamp_log" &
    		echo $rounded_pressure_hpa >> "$pressure_log" &
    		echo $inlettemp >> "$temp_log" &
    		echo $fanpwm >> "$fan_log" & # Log hardcoded value 100
        done

		wait $SLEEP_PID
	done
}

# Function to get service tag
get_service_tag() {
    local stored_tag=""
    
    # First check if we already stored the tag
    if [ -f "${LOGDIR}/service_tag.txt" ]; then
        stored_tag=$(cat "${LOGDIR}/service_tag.txt" 2>/dev/null)
        if [ -n "$stored_tag" ] && [ "$stored_tag" != "UNKNOWN" ]; then
            echo "$stored_tag"
            return 0
        fi
    fi
    
    # If no stored tag or it's "UNKNOWN", try to get it again
    local service_tag="UNKNOWN"
    if command -v racadm &> /dev/null; then
        # Use direct grep with "Service Tag" and proper extraction, make robust for set -e
        service_tag=$(racadm getsysinfo 2>/dev/null | grep "Service Tag" | awk -F= '{print $2}' | tr -d '[:space:]' || true)
        if [ -z "$service_tag" ]; then
            # Fallback: Try Asset Tag with proper extraction if Service Tag is empty, make robust for set -e
            service_tag=$(racadm getsysinfo 2>/dev/null | grep "Asset Tag" | awk -F= '{print $2}' | tr -d '[:space:]' || true)
        fi
        # Default to UNKNOWN if still empty after checking both
        [ -z "$service_tag" ] && service_tag="UNKNOWN"
    fi
    
    echo "$service_tag"
    return 0
}

# Function to collect TSR data
collect_tsr() {
    local stage=$1
    
    # Get service tag using improved method
    local service_tag=$(get_service_tag)
    
    # Dell v2.6 format: TSR_SERVICETAG_YYYY-MM-DD.HHhMMmSSs.zip
    local tsr_filename="${LOGDIR}/TSR_${service_tag}_${CURRENT_DATE}.zip"
    local max_attempts=3

    # Always use supportassist method for Debug TSR
    local use_techsupreport=false # Hardcoded to false

    for attempt in $(seq 1 $max_attempts); do
        display_message "INFO" "Starting ${stage} Debug TSR collection (attempt ${attempt}/${max_attempts})"

        # Check if there's already a running TSR job
        local existing_jobs=$(racadm jobqueue view 2>/dev/null)
        if [ $? -ne 0 ]; then
            display_message "WARNING" "racadm connectivity issue detected, waiting 30 seconds before retry"
            sleep 30
            existing_jobs=$(racadm jobqueue view 2>/dev/null)
            if [ $? -ne 0 ]; then
                display_message "ERROR" "Cannot connect to racadm, will retry on next attempt"
                sleep 60
                continue
            fi
        fi
        
        if echo "$existing_jobs" | grep -q "SupportAssist Collection.*Status=Running"; then
            display_message "WARNING" "A TSR collection job is already running"
            local running_job_id=$(echo "$existing_jobs" | grep -A1 "SupportAssist Collection.*Status=Running" | grep -o "JID_[0-9]*" | head -1)
            
            if [ -n "$running_job_id" ]; then
                display_message "INFO" "Using existing running job ID: $running_job_id"
                
                # Monitor the already running job
                monitor_tsr_job "$running_job_id"
                local monitor_result=$?
                
                if [ $monitor_result -eq 0 ]; then
                    # Try to download the TSR file using the confirmed working method
                    display_message "INFO" "Trying to locate and download TSR file from completed job"
                    sleep 10

                    # Attempt download using techsupreport export method (confirmed working)
                    display_message "INFO" "Attempting download using techsupreport export method"
                    if racadm techsupreport export -f "$tsr_filename" 2>/dev/null; then
                        if [ -f "$tsr_filename" ]; then
                            display_message "SUCCESS" "Downloaded ${stage} TSR file to ${tsr_filename} using techsupreport export"
                            update_context_file "${stage} TSR" "Successfully downloaded Debug TSR file via techsupreport export: ${tsr_filename}"
                            return 0
                        fi
                    fi
                    # If export failed, log warning and continue to next attempt (or finish)
                    display_message "WARNING" "techsupreport export download method failed"
                else
                    display_message "WARNING" "Monitoring of existing TSR job failed"
                fi
            fi
        # Check for failed jobs first
        elif echo "$existing_jobs" | grep -q "SupportAssist Collection.*Status=Failed"; then
            display_message "WARNING" "Found failed SupportAssist Collection jobs"
            local job_message=$(echo "$existing_jobs" | grep -A10 "SupportAssist Collection.*Status=Failed" | grep "Message" | head -1)
            
            if [ -n "$job_message" ]; then
                display_message "ERROR" "Previous job failed with message: $job_message"
                update_context_file "TSR Error" "Previous SupportAssist Collection job failed: $job_message"
            fi
            
            # Try to clear the failed jobs
            display_message "INFO" "Attempting to clear failed jobs before starting a new job..."
            racadm jobqueue delete -i JID_CLEARALL 2>/dev/null || true
            sleep 10
            
            # No running job, start a new one based on current method flag
            display_message "INFO" "Starting new Debug TSR collection job"
            local TSR_STATUS=""
            local JOB_ID=""
            local racadm_collect_exit_code=0 # Added

            # Use supportassist method with Debug parameter directly
            display_message "INFO" "Using supportassist method with Debug parameter"
            # MODIFIED LINE: Capture exit code explicitly
            TSR_STATUS=$(racadm supportassist collect -t Debug 2>&1) || racadm_collect_exit_code=$?

            # ADDED BLOCK to handle racadm_collect_exit_code (and CSIOR)
            if [ $racadm_collect_exit_code -ne 0 ]; then
                display_message "ERROR" "The 'racadm supportassist collect -t Debug' command failed with exit code ${racadm_collect_exit_code}."
                display_message "ERROR" "Command output: ${TSR_STATUS}"
                update_context_file "TSR Collection Error" "racadm supportassist collect command exited with ${racadm_collect_exit_code}. Output: ${TSR_STATUS}"

                # Attempt to handle CSIOR disabled error (RAC943)
                if [[ "$TSR_STATUS" == *"RAC943"* && "$TSR_STATUS" == *"Collect System Inventory On Restart"* && "$TSR_STATUS" == *"disabled"* ]]; then
                    display_message "WARNING" "RAC943 error: CSIOR is disabled. Attempting to enable it for the next retry."
                    update_context_file "CSIOR Auto-Fix" "RAC943 detected (CSIOR disabled). Attempting to enable."
                    if racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart 1; then
                        display_message "SUCCESS" "Successfully executed 'racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart 1'. TSR collection will be retried immediately."
                        update_context_file "CSIOR Auto-Fix" "Successfully enabled CSIOR. Value set to 1. Retrying collection immediately."
                        if [ $attempt -lt $max_attempts ]; then # If not the last attempt, skip delay and retry now
                            continue
                        fi
                    else
                        local set_csior_exit_code=$?
                        display_message "ERROR" "Failed to enable CSIOR using 'racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart 1' (Exit code: $set_csior_exit_code)."
                        update_context_file "CSIOR Auto-Fix Error" "Failed to enable CSIOR. Exit code: $set_csior_exit_code."
                    fi
                # Attempt to handle SupportAssist EULA not accepted error (SRV085)
                elif [[ "$TSR_STATUS" == *"SRV085"* && "$TSR_STATUS" == *"SupportAssist End User License Agreement"* && "$TSR_STATUS" == *"not accepted"* ]]; then
                    display_message "WARNING" "SRV085 error: SupportAssist EULA not accepted. Attempting to accept it for the next retry."
                    update_context_file "EULA Auto-Fix" "SRV085 detected (EULA not accepted). Attempting to accept."
                    if racadm supportassist accepteula; then
                        display_message "SUCCESS" "Successfully executed 'racadm supportassist accepteula'. TSR collection will be retried immediately."
                        update_context_file "EULA Auto-Fix" "Successfully accepted SupportAssist EULA. Retrying collection immediately."
                        if [ $attempt -lt $max_attempts ]; then # If not the last attempt, skip delay and retry now
                            continue
                        fi
                    else
                        local accept_eula_exit_code=$?
                        display_message "ERROR" "Failed to accept SupportAssist EULA using 'racadm supportassist accepteula' (Exit code: $accept_eula_exit_code)."
                        update_context_file "EULA Auto-Fix Error" "Failed to accept SupportAssist EULA. Exit code: $accept_eula_exit_code."
                    fi
                fi
            fi
            # END MODIFIED BLOCK

            JOB_ID=$(echo "$TSR_STATUS" | grep -o "JID_[0-9]*") # This will likely be empty if racadm_collect_exit_code was non-zero

            if [ -z "$JOB_ID" ]; then
                # Slightly rephrased for clarity if racadm_collect_exit_code was already reported
                if [ $racadm_collect_exit_code -ne 0 ]; then
                    display_message "WARNING" "Failed to extract job ID (racadm command previously failed with exit code ${racadm_collect_exit_code}). Response: $TSR_STATUS"
                else
                    display_message "WARNING" "Failed to extract job ID from response: $TSR_STATUS"
                fi

                # Check for various error patterns
                if echo "$TSR_STATUS" | grep -q -E "SRV090|RAC1050|Collection Operation did not complete|Unable to start|A TSR collection task is already in progress"; then
                    display_message "ERROR" "SupportAssist Collection Operation failed (as indicated by output): $TSR_STATUS"
                    update_context_file "TSR Error" "SupportAssist Collection Operation failed (as indicated by output): $TSR_STATUS"
                elif [ $racadm_collect_exit_code -ne 0 ]; then
                    # This case is hit if racadm exited non-zero but not matching known error strings.
                    # The specific exit code and output are already logged by the block above.
                    display_message "ERROR" "SupportAssist Collection failed due to previous racadm command error (exit code ${racadm_collect_exit_code})."
                    # update_context_file already done by the new block
                fi
                    
                # If this is the last attempt, continue without collection
                if [ $attempt -eq $max_attempts ]; then
                    display_message "ERROR" "TSR collection failed after $max_attempts attempts."
                    update_context_file "TSR Error" "TSR collection failed after $max_attempts attempts."
                        
                    display_message "WARNING" "Continuing without ${stage} TSR collection" # Moved message
                    update_context_file "Warning" "Continuing without ${stage} TSR collection"
                    return 0  # Return 0 to continue script execution
                fi
            fi
            
            display_message "INFO" "Monitoring TSR collection job: $JOB_ID"
            
            # Monitor job progress
            monitor_tsr_job "$JOB_ID"
            local monitor_result=$?
            
            if [ $monitor_result -eq 0 ]; then
                # Try to download the TSR file using the confirmed working method
                display_message "INFO" "Trying to locate and download TSR file from completed job"
                sleep 10

                # Attempt download using techsupreport export method (confirmed working)
                display_message "INFO" "Attempting download using techsupreport export method"
                if racadm techsupreport export -f "$tsr_filename" 2>/dev/null; then
                    if [ -f "$tsr_filename" ]; then
                        display_message "SUCCESS" "Downloaded ${stage} TSR file to ${tsr_filename} using techsupreport export"
                        update_context_file "${stage} TSR" "Successfully downloaded Debug TSR file via techsupreport export: ${tsr_filename}"
                        return 0
                    fi
                fi
                # If export failed, log warning and continue to next attempt (or finish)
                display_message "WARNING" "techsupreport export download method failed"
            else
                display_message "WARNING" "TSR job monitoring failed on attempt ${attempt}"
                # Continue with next attempt
            fi
        else
            # No running job, start a new one based on current method flag
            display_message "INFO" "Starting new Debug TSR collection job"
            local TSR_STATUS=""
            local JOB_ID=""
            local racadm_collect_exit_code=0 # Added

            # Use supportassist method with Debug parameter directly
            display_message "INFO" "Using supportassist method with Debug parameter"
            # MODIFIED LINE: Capture exit code explicitly
            TSR_STATUS=$(racadm supportassist collect -t Debug 2>&1) || racadm_collect_exit_code=$?

            # ADDED BLOCK to handle racadm_collect_exit_code (and CSIOR)
            if [ $racadm_collect_exit_code -ne 0 ]; then
                display_message "ERROR" "The 'racadm supportassist collect -t Debug' command failed with exit code ${racadm_collect_exit_code}."
                display_message "ERROR" "Command output: ${TSR_STATUS}"
                update_context_file "TSR Collection Error" "racadm supportassist collect command exited with ${racadm_collect_exit_code}. Output: ${TSR_STATUS}"

                # Attempt to handle CSIOR disabled error (RAC943)
                if [[ "$TSR_STATUS" == *"RAC943"* && "$TSR_STATUS" == *"Collect System Inventory On Restart"* && "$TSR_STATUS" == *"disabled"* ]]; then
                    display_message "WARNING" "RAC943 error: CSIOR is disabled. Attempting to enable it for the next retry."
                    update_context_file "CSIOR Auto-Fix" "RAC943 detected (CSIOR disabled). Attempting to enable."
                    if racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart 1; then
                        display_message "SUCCESS" "Successfully executed 'racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart 1'. TSR collection will be retried immediately."
                        update_context_file "CSIOR Auto-Fix" "Successfully enabled CSIOR. Value set to 1. Retrying collection immediately."
                        if [ $attempt -lt $max_attempts ]; then # If not the last attempt, skip delay and retry now
                            continue
                        fi
                    else
                        local set_csior_exit_code=$?
                        display_message "ERROR" "Failed to enable CSIOR using 'racadm set LifecycleController.LCAttributes.CollectSystemInventoryOnRestart 1' (Exit code: $set_csior_exit_code)."
                        update_context_file "CSIOR Auto-Fix Error" "Failed to enable CSIOR. Exit code: $set_csior_exit_code."
                    fi
                # Attempt to handle SupportAssist EULA not accepted error (SRV085)
                elif [[ "$TSR_STATUS" == *"SRV085"* && "$TSR_STATUS" == *"SupportAssist End User License Agreement"* && "$TSR_STATUS" == *"not accepted"* ]]; then
                    display_message "WARNING" "SRV085 error: SupportAssist EULA not accepted. Attempting to accept it for the next retry."
                    update_context_file "EULA Auto-Fix" "SRV085 detected (EULA not accepted). Attempting to accept."
                    if racadm supportassist accepteula; then
                        display_message "SUCCESS" "Successfully executed 'racadm supportassist accepteula'. TSR collection will be retried immediately."
                        update_context_file "EULA Auto-Fix" "Successfully accepted SupportAssist EULA. Retrying collection immediately."
                        if [ $attempt -lt $max_attempts ]; then # If not the last attempt, skip delay and retry now
                            continue
                        fi
                    else
                        local accept_eula_exit_code=$?
                        display_message "ERROR" "Failed to accept SupportAssist EULA using 'racadm supportassist accepteula' (Exit code: $accept_eula_exit_code)."
                        update_context_file "EULA Auto-Fix Error" "Failed to accept SupportAssist EULA. Exit code: $accept_eula_exit_code."
                    fi
                fi
            fi
            # END MODIFIED BLOCK

            JOB_ID=$(echo "$TSR_STATUS" | grep -o "JID_[0-9]*") # This will likely be empty if racadm_collect_exit_code was non-zero

            if [ -z "$JOB_ID" ]; then
                # Slightly rephrased for clarity if racadm_collect_exit_code was already reported
                if [ $racadm_collect_exit_code -ne 0 ]; then
                    display_message "WARNING" "Failed to extract job ID (racadm command previously failed with exit code ${racadm_collect_exit_code}). Response: $TSR_STATUS"
                else
                    display_message "WARNING" "Failed to extract job ID from response: $TSR_STATUS"
                fi

                # Check for various error patterns
                if echo "$TSR_STATUS" | grep -q -E "SRV090|RAC1050|Collection Operation did not complete|Unable to start|A TSR collection task is already in progress"; then
                    display_message "ERROR" "SupportAssist Collection Operation failed (as indicated by output): $TSR_STATUS"
                    update_context_file "TSR Error" "SupportAssist Collection Operation failed (as indicated by output): $TSR_STATUS"
                elif [ $racadm_collect_exit_code -ne 0 ]; then
                    # This case is hit if racadm exited non-zero but not matching known error strings.
                    # The specific exit code and output are already logged by the block above.
                    display_message "ERROR" "SupportAssist Collection failed due to previous racadm command error (exit code ${racadm_collect_exit_code})."
                    # update_context_file already done by the new block
                fi
                    
                # If this is the last attempt, continue without collection
                if [ $attempt -eq $max_attempts ]; then
                    display_message "ERROR" "TSR collection failed after $max_attempts attempts."
                    update_context_file "TSR Error" "TSR collection failed after $max_attempts attempts."
                        
                    display_message "WARNING" "Continuing without ${stage} TSR collection" # Moved message
                    update_context_file "Warning" "Continuing without ${stage} TSR collection"
                    return 0  # Return 0 to continue script execution
                fi
            fi
            
            display_message "INFO" "Monitoring TSR collection job: $JOB_ID"
            
            # Monitor job progress
            monitor_tsr_job "$JOB_ID"
            local monitor_result=$?
            
            if [ $monitor_result -eq 0 ]; then
                # Try to download the TSR file using the confirmed working method
                display_message "INFO" "Trying to locate and download TSR file from completed job"
                sleep 10

                # Attempt download using techsupreport export method (confirmed working)
                display_message "INFO" "Attempting download using techsupreport export method"
                if racadm techsupreport export -f "$tsr_filename" 2>/dev/null; then
                    if [ -f "$tsr_filename" ]; then
                        display_message "SUCCESS" "Downloaded ${stage} TSR file to ${tsr_filename} using techsupreport export"
                        update_context_file "${stage} TSR" "Successfully downloaded Debug TSR file via techsupreport export: ${tsr_filename}"
                        return 0
                    fi
                fi
                # If export failed, log warning and continue to next attempt (or finish)
                display_message "WARNING" "techsupreport export download method failed"
            else
                display_message "WARNING" "TSR job monitoring failed on attempt ${attempt}"
                # Continue with next attempt
            fi
        fi
        
        # Add delay between attempts
        if [ $attempt -lt $max_attempts ]; then
            display_message "INFO" "Waiting 30 seconds before next attempt"
            sleep 30
        fi
    done
    
    # If we reached here, all attempts failed
    display_message "ERROR" "Failed to collect ${stage} TSR data after ${max_attempts} attempts"
    update_context_file "${stage} TSR" "Failed to collect TSR data after ${max_attempts} attempts"
    
    # Always continue the script
    display_message "WARNING" "Continuing without ${stage} TSR collection"
    update_context_file "Warning" "Continuing without ${stage} TSR collection"
    return 0  # Return 0 to continue script execution
}

# Function to monitor TSR job progress
monitor_tsr_job() {
    local job_id=$1
    local max_wait=1800  # 30 minutes (increased from 10 minutes)
    local start_time=$(date +%s)
    local end_time=$((start_time + max_wait))
    local current_time=$start_time
    local last_progress=0
    
    while [ $current_time -lt $end_time ]; do
        local job_status=$(racadm jobqueue view -i $job_id)
        local status=$(echo "$job_status" | grep "Status" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        local progress=$(echo "$job_status" | grep "Percent Complete" | cut -d'[' -f2 | cut -d']' -f1 | tr -d '[:space:]')
        
        # If progress is different from last_progress, update
        if [ "$progress" != "$last_progress" ]; then
            display_message "INFO" "TSR collection progress: $progress"
            last_progress=$progress
        fi
        
        # Check if job is completed
        if [ "$status" = "Completed" ]; then
            display_message "SUCCESS" "TSR collection job completed successfully"
            return 0
        elif [ "$status" = "Failed" ] || [ "$status" = "CompletedWithErrors" ]; then
            local message=$(echo "$job_status" | grep "Message" | cut -d'=' -f2)
            display_message "ERROR" "TSR collection job failed: $message"
            return 1
        fi
        
        sleep 10
        current_time=$(date +%s)
    done
    
    display_message "ERROR" "TSR collection job timed out after ${max_wait} seconds"
    return 1
}

# Function to run thermal test
run_thermal_test() {
    echo "Starting thermal test..."
    local start_time=$(date +%s)
    local end_time=$((start_time + THERMAL_DURATION))
    local current_time

    # Save current fan speed before changing (from dcgmprofrunner.sh v2.6)
    ORIGINAL_FAN_SPEED=$(get_minimum_fan_speed)
    display_message "INFO" "Saved original fan speed offset: ${ORIGINAL_FAN_SPEED}"
    update_context_file "Fan Control" "Saved original fan speed offset: ${ORIGINAL_FAN_SPEED}"
    
    # Set fans high using racadm
    display_message "INFO" "Setting fans to max speed using racadm..."
    if racadm set system.thermalsettings.FanSpeedOffset 3 > /dev/null 2>&1; then
        display_message "SUCCESS" "Fan speed offset set to high (3). Waiting for spin-up..."
        update_context_file "Fan Control" "Set fan speed offset to high (3)"
        sleep 20
    else
        display_message "ERROR" "Failed to set fan speed offset using racadm. Check racadm functionality."
        update_context_file "Fan Control Error" "Failed to set fan speed offset using racadm."
        # Decide whether to exit or continue with warning?
        read -p "Failed to set fan speed. Continue anyway? (y/N): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            echo "Exiting due to fan control failure."
            exit 4 # Use config/setup error code
        fi
        display_message "WARNING" "Continuing test despite fan control failure."
        update_context_file "Warning" "Continuing test despite fan control failure."
    fi

    echo "Starting GPU stress test..."
    # display_message "NOTE" "GPU stress test will show 'test PASSED' messages at completion - these are normal and can be ignored"
    
    # Try to set persistent mode safely
    if ! nvidia-smi -pm 1; then
        echo "WARNING: Failed to set persistent mode, this may affect the test"
        update_context_file "Warning" "Failed to set GPU persistent mode, continuing anyway"
        read -p "Do you want to continue the test without persistent mode? (y/n): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            echo "Exiting as requested"
            exit 6  # GPU thermal test error
        fi
    fi
    
    # Get the appropriate dcgmproftester binary based on CUDA version (v2.6 style)
    local dcgm_binary
    dcgm_binary=$(get_dcgmproftester_cmd)
    
    if [ -z "$dcgm_binary" ]; then
        # No binary found at all
        echo "WARNING: No dcgmproftester binary found (tried versions 11, 12, 13)"
        update_context_file "Warning" "Workload binary not found, continuing with monitoring only"
        read -p "Do you want to continue with monitoring only (no GPU stress test)? (y/n): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            echo "Exiting as requested"
            exit 6  # GPU thermal test error
        fi
        WORKLOAD_PID=0
    else
        # Start the dcgmproftester with the detected binary
        # Dell v2.6 creates: dcgmproftester.log and tensor_active_*.results files
        display_message "INFO" "Starting GPU stress test with ${dcgm_binary}..."
        {
            # Run dcgmproftester from LOGDIR so tensor_active_*.results files are created there
            cd "${LOGDIR}"
            $dcgm_binary --no-dcgm-validation --max-processes 0 -t $DCGM_TARGET -d $THERMAL_DURATION > "${LOGDIR}/dcgmproftester.log" 2>&1 &
            WORKLOAD_PID=$!
            cd - > /dev/null
            update_context_file "Workload" "Started ${dcgm_binary} with PID $WORKLOAD_PID"
        } || {
            echo "WARNING: Error starting ${dcgm_binary}"
            update_context_file "Warning" "Failed to start workload, continuing with monitoring only"
            read -p "Do you want to continue with monitoring only (no GPU stress test)? (y/n): " choice
            if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
                echo "Exiting as requested"
                exit 6  # GPU thermal test error
            fi
            WORKLOAD_PID=0
        }
    fi

    # Start nvidia-smi monitoring in background
    local metrics_file="${LOGDIR}/gpu_metrics_raw.csv" # Use raw suffix initially
    nvidia-smi --query-gpu=serial,name,timestamp,index,temperature.gpu,temperature.memory,temperature.gpu.tlimit,power.draw,clocks.current.sm,clocks_throttle_reasons.active,utilization.gpu --loop=1 --format=csv --filename=${metrics_file} &
    NVIDIA_SMI_PID=$!
    update_context_file "Monitoring" "Started nvidia-smi monitoring with PID $NVIDIA_SMI_PID writing to ${metrics_file}"

    # Start BMC getter in background
    bmc_getter "$altitude_ft" "$LOGDIR" &
    BMC_PID=$!
    update_context_file "BMC Monitoring" "Started BMC data collection with PID $BMC_PID"

    while true; do
        current_time=$(date +%s)
        if [ $current_time -ge $end_time ]; then
            break
        fi

        # Get GPU index, serial, and temperature
        # Query for serial number as well
        local gpu_info=$(nvidia-smi --query-gpu=index,serial,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
        local cpu_temp=$(ipmitool sdr type temperature | grep CPU | awk '{print $3}' 2>/dev/null || echo "N/A") # Add error handling for ipmitool
        
        # Display temperatures with red highlighting for high GPU temps
        echo "Current temperatures:"
        # Process the gpu_info line by line
        echo "$gpu_info" | while IFS=',' read -r index serial temp; do
            # Trim potential whitespace
            index=$(echo "$index" | tr -d ' ')
            serial=$(echo "$serial" | tr -d ' ')
            temp=$(echo "$temp" | tr -d ' ')

            # Basic validation: ensure temp looks like a number
            if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                if (( $(echo "$temp >= 85" | bc -l) )); then
                    # High temperature - include serial
                    echo -e "  GPU $index (Serial: $serial): \e[1;31m${temp}°C\e[0m (HIGH TEMPERATURE!)"
                    # Update context file (no change needed here, already includes index)
                    update_context_file "High Temperature" "GPU $index (Serial: $serial) reached ${temp}°C at $(date)"
                else
                    # Normal temperature - include serial
                    echo -e "  GPU $index (Serial: $serial): ${temp}°C"
                fi
            else
                # Invalid temperature reading
                 echo -e "  GPU $index (Serial: $serial): ${temp} (Invalid Reading)"
            fi
        done
        echo "  CPU: ${cpu_temp}°C"

        local elapsed_time=$((current_time - start_time))
        if [ $elapsed_time -ge $TSR_MIDRUN_DELAY ]; then
            # Collect a TSR mid-test
            display_message "INFO" "Collecting mid-test TSR report at the halfway mark"
            collect_tsr "mid-test"
            update_context_file "Mid-test TSR" "Collected TSR report (TSR-*) at the test halfway mark"
            TSR_MIDRUN_DELAY=$((THERMAL_DURATION + 1))  # Prevent multiple mid-run collections
        fi

        sleep 30
    done

    # Wait for workload to complete and add extra time for cooldown
    echo "Waiting for workload to complete..."
    if [ $WORKLOAD_PID -ne 0 ]; then
        # Use wait with timeout to avoid hanging if workload crashes
        timeout 300 wait $WORKLOAD_PID 2>/dev/null || true
        update_context_file "Workload" "Workload process $WORKLOAD_PID completed or timed out"
    fi
    
    # Keep monitoring for additional 60 seconds to capture cooldown
    echo "Cooldown period (60 seconds)..."
    sleep 60
    
    # Now safely stop monitoring processes
    display_message "INFO" "Stopping nvidia-smi monitoring..."
    if ps -p $NVIDIA_SMI_PID > /dev/null; then
        kill -SIGINT $NVIDIA_SMI_PID
        wait $NVIDIA_SMI_PID 2>/dev/null || true
    fi
    update_context_file "Monitoring" "Stopped nvidia-smi monitoring"

    display_message "INFO" "Stopping BMC data collection..."
    if ps -p $BMC_PID > /dev/null; then
        # Use SIGTERM or SIGKILL for background process
        kill -TERM $BMC_PID 2>/dev/null || kill -KILL $BMC_PID 2>/dev/null
        wait $BMC_PID 2>/dev/null || true # Wait briefly
    fi
    update_context_file "BMC Monitoring" "Stopped BMC data collection"

    # Restore original fan speed using racadm (from dcgmprofrunner.sh v2.6)
    local restore_speed="${ORIGINAL_FAN_SPEED:-0}"  # Default to 0 if not set
    display_message "INFO" "Restoring fan speed to original setting (${restore_speed})..."
    if racadm set system.thermalsettings.FanSpeedOffset "$restore_speed" > /dev/null 2>&1; then
        display_message "SUCCESS" "Fan speed offset restored to original (${restore_speed})."
        update_context_file "Fan Control" "Restored fan speed offset to original (${restore_speed})"
    else
        # Log warning but don't exit here, test is already done
        display_message "WARNING" "Failed to restore fan speed offset using racadm."
        update_context_file "Fan Control Warning" "Failed to restore fan speed offset using racadm."
    fi

    echo "$(date) Done workload $WORKLOAD_PID" # No longer add to csv here
    echo "Stopped telemetry collection" # No longer add to csv here
    update_context_file "Thermal Test" "Completed thermal test and cooldown period"

    # Generate temperature summary after test completion (will use the final processed file later)
    # We call process_bmc_data first, then failure check, then summary
    # generate_temp_summary # Moved lower
}

# Function to process BMC data and merge with nvidia-smi data
process_bmc_data() {
    local raw_metrics_file="${LOGDIR}/gpu_metrics_raw.csv"
    # Dell v2.6 format: thermal_results.hostname.target.duration.date.csv
    local final_metrics_file="${LOGDIR}/thermal_results.$(hostname).${DCGM_TARGET}.${THERMAL_DURATION}.${CURRENT_DATE}.csv"
    local tmp_metrics_file="${LOGDIR}/thermal_results.tmp"

    local timestamp_log="${LOGDIR}/bmctimestamp.log"
    local pressure_log="${LOGDIR}/bmcairpressure.log"
    local temp_log="${LOGDIR}/bmcinlettemp.log"
    local fan_log="${LOGDIR}/bmcfanPWM.log"

    display_message "INFO" "Processing and merging BMC data into ${final_metrics_file}"
    update_context_file "Data Processing" "Starting merge of BMC data"

    # Check if raw metrics file exists and has data
    if [ ! -s "$raw_metrics_file" ]; then
        display_message "ERROR" "Raw GPU metrics file is missing or empty: ${raw_metrics_file}"
        update_context_file "Data Processing Error" "Raw GPU metrics file missing or empty, cannot merge BMC data."
        # Create an empty final file? Or handle error upstream?
        # Let's create an empty file with header for consistency
        echo "hostname,dcgm target,duration [s],serial,name,timestamp,index,temperature.gpu,temperature.memory,temperature.gpu.tlimit,power.draw,clocks.current.sm,clocks_throttle_reasons.active,utilization.gpu,bmc.timestamp,bmc.airpressure,bmc.inlet.temp,bmc.fan.pwm" > "$final_metrics_file"
        return 1 # Indicate failure
    fi

    # Add run info prefix to raw file
    local RUN_INFO="$(hostname),$DCGM_TARGET,$THERMAL_DURATION"
    awk -v info="$RUN_INFO" 'NR > 1 {print info","$0}' "$raw_metrics_file" > "$tmp_metrics_file" # Skip header

    # Get number of data lines (excluding header)
    local numlines=$(wc -l < "$tmp_metrics_file")
    display_message "INFO" "Found $numlines data lines in nvidia-smi output."

    # Check that BMC files exist before proceeding (keep this part)
    for bmc_file in "$timestamp_log" "$pressure_log" "$temp_log" "$fan_log"; do
        if [ ! -f "$bmc_file" ]; then
             display_message "ERROR" "Required BMC log file missing: $bmc_file. Cannot merge data."
             update_context_file "Data Processing Error" "BMC log file missing: $bmc_file"
             rm -f "$tmp_metrics_file" # Clean up intermediate file
             echo "hostname,dcgm target,duration [s],serial,name,timestamp,index,temperature.gpu,temperature.memory,temperature.gpu.tlimit,power.draw,clocks.current.sm,clocks_throttle_reasons.active,utilization.gpu,bmc.timestamp,bmc.airpressure,bmc.inlet.temp,bmc.fan.pwm,altitude_ft" > "$final_metrics_file"
             return 1
        fi
    done


    # Prepare header for the final file (matches Dell v2.6 format exactly)
    local smi_header=$(head -n 1 "$raw_metrics_file")
    echo "hostname,dcgm target,duration [s],${smi_header},bmc.timestamp,bmc.airpressure,bmc.inlet.temp,bmc.fan.pwm,altitude_ft" > "$final_metrics_file"

    # Process line by line
    for line_number in $(seq 1 $numlines)
    do
        local rawline=$(sed "${line_number}q;d" "${tmp_metrics_file}")
        # Get corresponding BMC data (line number + 1 because BMC files have headers)
        # Even with 8x logging, reading line N+1 gets the *first* entry for that second.
        local bmc_line_num=$((line_number + 1))

        # Read BMC values and default to N/A if sed returns empty string
        local bmctimestamp=$(sed "${bmc_line_num}q;d" "$timestamp_log")
        [ -z "$bmctimestamp" ] && bmctimestamp="N/A"

        local bmcairpressure=$(sed "${bmc_line_num}q;d" "$pressure_log")
        [ -z "$bmcairpressure" ] && bmcairpressure="N/A"

        local bmcinlettemp=$(sed "${bmc_line_num}q;d" "$temp_log")
        [ -z "$bmcinlettemp" ] && bmcinlettemp="N/A"

        local bmcfanPWM=$(sed "${bmc_line_num}q;d" "$fan_log")
        [ -z "$bmcfanPWM" ] && bmcfanPWM="N/A"

        echo "$rawline,$bmctimestamp,$bmcairpressure,$bmcinlettemp,$bmcfanPWM,$altitude_ft" >> "$final_metrics_file"
        # Provide progress feedback less often to avoid spamming console
        if (( line_number % 100 == 0 )) || [ "$line_number" -eq "$numlines" ]; then
             echo -ne "Processed lines [$line_number/$numlines]\r"
        fi
    done

    echo "" # Newline after progress indicator
    display_message "SUCCESS" "Finished merging BMC data."
    update_context_file "Data Processing" "Finished merging BMC data into ${final_metrics_file}"


    # Clean up intermediate and raw files
    rm -f "$tmp_metrics_file"
    rm -f "$raw_metrics_file"
    rm -f "$timestamp_log"
    rm -f "$pressure_log"
    rm -f "$temp_log"
    rm -f "$fan_log"

    return 0 # Indicate success
}

# DEPRECATED: Function to check for failures (from old dcgmprofrunner.sh)
# As of v2.6 alignment, Dell uses an internal NVIDIA tool for failure detection.
# This function is no longer called but kept for reference.
# Results must be submitted to Dell for RMA determination.
check_failures() {
    local metrics_file="$1" # Path to the final merged metrics file
    local alt_ft="$2"       # Altitude in feet

    display_message "INFO" "Checking for thermal failures based on criteria..."
    update_context_file "Failure Check" "Starting failure analysis on ${metrics_file}"

    local fail_log="${LOGDIR}/faillog.log"
    echo "# Failing rows from ${metrics_file}" > "$fail_log" # Add header to fail log

    if [ ! -s "$metrics_file" ]; then
         display_message "ERROR" "Metrics file is missing or empty: ${metrics_file}. Cannot perform failure check."
         update_context_file "Failure Check Error" "Metrics file missing or empty."
         # Return a specific code? Let's return 2 for "cannot check"
         return 2
    fi

    local numlines=$(wc -l < "$metrics_file")
    # Start check from line 2 (skip header)
    local check_count=0
    local fail_count=0

    for ((line_number=2; line_number<=$numlines; line_number++))
    do
        local rawline=$(sed "${line_number}q;d" "$metrics_file")

        # Skip empty lines if any somehow exist
        if [ -z "${rawline// }" ]; then
            continue
        fi

        check_count=$((check_count + 1))

        # Extract necessary values using correct column numbers for the merged file
        # 8: temp.gpu, 10: temp.gpu.tlimit, 17: bmc.inlet.temp
        local Tgpuavg=$(echo "$rawline" | cut -d ',' -f 8 | tr -d ' ')
        local Tlimitnum=$(echo "$rawline" | cut -d ',' -f 10 | tr -d ' ')
        local Tambnum=$(echo "$rawline" | cut -d ',' -f 17 | tr -d ' ') # Inlet temp from BMC


        # Validate that extracted numbers are actually numbers before using in bc
        local valid_numbers=true
        for val in "$Tgpuavg" "$Tlimitnum" "$Tambnum" "$alt_ft"; do
             # Allow N/A from BMC getter
             if [ "$val" == "N/A" ]; then
                 valid_numbers=false
                 # display_message "WARNING" "Skipping failure check for line $line_number due to N/A value." # <-- Hide this warning
                 break # Skip this line's check
             fi
             # Check if it's a valid number (integer or float, possibly negative)
             if ! [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                 # display_message "WARNING" "Invalid numeric value detected on line $line_number ('$val'). Skipping failure check for this line." # <-- Hide this warning too
                 valid_numbers=false
                 break # Skip this line's check
             fi
        done

        if ! $valid_numbers; then
            continue # Move to the next line
        fi

        # Perform calculations using bc
        local failnum1=$(echo "scale=4; $Tambnum + $Tlimitnum + (-0.1) * $Tgpuavg + 8.5 - 35 + 0.85 * $alt_ft / 1000" | bc -l)
		local failnum2=$(echo "scale=4; 52 - $Tgpuavg + $Tambnum + 0.85 * $alt_ft / 1000" | bc -l)

        # Check failure conditions
		if (( $(echo "$failnum1 <= 0" | bc -l) )) || (( $(echo "$failnum2 <= 0" | bc -l) )); then
			echo "$rawline" >> "$fail_log"
            fail_count=$((fail_count + 1))
		fi

        # Provide progress feedback less often
        if (( check_count % 100 == 0 )) || [ "$line_number" -eq "$numlines" ]; then
             echo -ne "Checked lines [$check_count/$(($numlines-1))]\r"
        fi
	done

    echo "" # Newline after progress

    local failedlines=$fail_count # Use the counter instead of wc -l on fail_log (which includes header)

    display_message "INFO" "Failure check complete. Found $failedlines failing instances out of $check_count checked lines."

    # Determine pass/fail based on threshold (e.g., 180 instances)
    local failure_threshold=180
    if [ $failedlines -gt $failure_threshold ]; then
        display_message "ERROR" "FAILURE! Test failed with $failedlines instances exceeding thermal thresholds (threshold: $failure_threshold)."
        display_message "ERROR" "Failing data points logged to: $fail_log"
        display_message "ERROR" "SUBMIT THE .csv FILE (${metrics_file}) AND LOGS TO SUPPORT/NVIDIA FOR RMA!"
        update_context_file "Failure Check Result" "FAIL ($failedlines > $failure_threshold instances). Log: $fail_log"
        return 1 # Return 1 for Failure
    else
        display_message "SUCCESS" "PASS! Test passed with $failedlines instances exceeding thermal thresholds (threshold: $failure_threshold)."
        update_context_file "Failure Check Result" "PASS ($failedlines <= $failure_threshold instances)."
        # Optionally remove the fail log if it only contains the header
        if [ $failedlines -eq 0 ]; then
            rm -f "$fail_log"
        else
             display_message "INFO" "Details of ($failedlines) failing instances logged to: $fail_log"
        fi
        return 0 # Return 0 for Pass
    fi
}

# Function to generate temperature summary
generate_temp_summary() {
    # Find the Dell-format thermal results file
    local metrics_file=$(find "${LOGDIR}" -maxdepth 1 -name "thermal_results.*.csv" -type f | head -1)
    if [[ -z "$metrics_file" ]]; then
        display_message "WARNING" "No thermal_results CSV found, skipping temperature summary"
        return 1
    fi
    local summary_file="${LOGDIR}/temperature_summary.txt"
    local current_date=$(date '+%Y-%m-%d-%H:%M:%S')
    
    # Check if metrics file exists before proceeding
    if [ ! -s "$metrics_file" ]; then
        display_message "ERROR" "Metrics file missing or empty: ${metrics_file}. Cannot generate temperature summary."
        update_context_file "Temp Summary Error" "Metrics file missing or empty."
        # Create an empty summary file?
        echo "$current_date - ERROR: Metrics file missing" > "$summary_file"
        return 1 # Indicate failure
    fi

    echo "$current_date" > "$summary_file"
    echo "GPU temperatures:" >> "$summary_file"
    
    local total_temp=0
    local gpu_count=0
    local highest_temp=0
    local line_count=0
    local numeric_gpu_temps=()
    # local hot_gpus_indices=() # Replaced by hot_gpus_info
    local hot_gpus_info=()      # Store "index:serial" pairs for hot GPUs

    # Process CSV file to get temperatures per GPU, skipping header
    # Adjust read to capture serial (col 4), index (col 7), temp_gpu (col 8)
    # --- OLD PIPELINE CAUSING SUBSHELL ISSUE ---
    # tail -n +2 "$metrics_file" | while IFS=',' read -r _ _ _ serial _ _ index temp_gpu rest; do 
    # --- USE PROCESS SUBSTITUTION INSTEAD ---
    while IFS=',' read -r _ _ _ serial _ _ index temp_gpu rest; do 
        line_count=$((line_count + 1))
        # Clean up the values
        serial=$(echo "$serial" | tr -d ' ')
        index=$(echo "$index" | tr -d ' ')
        # temp_gpu=$(echo "$temp_gpu" | tr -d ' ') # <-- OLD cleaning
        temp_gpu=$(echo "$temp_gpu" | sed 's/[^0-9.]//g') # <-- NEW aggressive cleaning

        # Validate temp_gpu is a number before processing
        if [[ "$temp_gpu" =~ ^[0-9]+([.][0-9]+)?$ ]]; then # <--- Step 2: Validate is numeric
            # --- If it IS numeric ---
            numeric_gpu_temps+=("$temp_gpu") 
            gpu_count=$((gpu_count + 1))
            total_temp=$(echo "scale=4; $total_temp + $temp_gpu" | bc)

            # Check threshold and record GPU index:serial if hot
            if (( $(echo "$temp_gpu >= 85" | bc -l) )); then
                 echo "$index, $serial, ${temp_gpu} **HIGH TEMPERATURE**" >> "$summary_file"
                # hot_gpus_indices+=("$index") # Old way
                hot_gpus_info+=("$index:$serial") # Store index:serial pair
            else
                echo "$index, $serial, $temp_gpu" >> "$summary_file"
            fi
            
            # Update highest temp if current temp is higher
            if (( $(echo "$temp_gpu > $highest_temp" | bc -l) )); then
                highest_temp=$temp_gpu
            fi
        else
            # --- If it's NOT numeric ---
            # display_message "WARNING" "Non-numeric GPU temp ('$temp_gpu') found on line $((line_count + 1)) of metrics file. Skipping for stats." # <-- Hide this warning
            echo "$index, $serial, ${temp_gpu} (skipped)" >> "$summary_file"
        fi
    # --- MODIFY END OF LOOP TO USE PROCESS SUBSTITUTION ---
    # done # <--- End of loop reading the file (Old pipeline end)
    done < <(tail -n +2 "$metrics_file") # <--- End of loop using process substitution
    
    # Calculate statistics using collected valid temps
    local avg_temp="N/A"
    local last_temp="N/A"
    if [ "${#numeric_gpu_temps[@]}" -gt 0 ]; then
        # Calculate average from valid temps
        avg_temp=$(echo "scale=2; $total_temp / $gpu_count" | bc)
        # Get last valid temperature collected
        last_temp=${numeric_gpu_temps[-1]}
        # Find peak from valid temps (already tracked by highest_temp)
    else
        display_message "WARNING" "No valid numeric GPU temperatures found in metrics file to calculate statistics."
        highest_temp=0 # Reset peak if no valid data
    fi

    echo -e "\nAverage GPU temp: ${avg_temp}°C" >> "$summary_file"

    # Report hot GPUs based on collected info
    if [ "${#hot_gpus_info[@]}" -gt 0 ]; then
        # Get unique index:serial pairs using printf and sort -u
        local unique_hot_gpus_info=($(printf "%s\n" "${hot_gpus_info[@]}" | sort -u))
        local hot_gpu_count=${#unique_hot_gpus_info[@]}

        echo -e "\n!!! HIGH TEMPERATURE WARNING !!!" >> "$summary_file"
        echo "The following $hot_gpu_count unique GPUs exceeded the 85°C threshold during testing:" >> "$summary_file"
        
        # Display general warning to terminal first
        display_message "WARNING" "$hot_gpu_count unique GPUs exceeded 85°C temperature threshold during testing:"
        
        for gpu_info in "${unique_hot_gpus_info[@]}"; do
            # Split the info string back into index and serial
            local gpu_index=$(echo "$gpu_info" | cut -d':' -f1)
            local gpu_serial=$(echo "$gpu_info" | cut -d':' -f2)
            # Log to summary file
            echo "  - GPU $gpu_index (Serial: $gpu_serial)" >> "$summary_file" 
            # Also display specific warning to terminal for this GPU
            display_message "WARNING" "  -> GPU $gpu_index (Serial: $gpu_serial)" 
        done
        echo "These GPUs may require further investigation for thermal issues." >> "$summary_file"
            
        update_context_file "Temperature Warning" "$hot_gpu_count unique GPUs exceeded 85°C threshold during testing (see summary for serials)"
        # General display_message already handled above
        # display_message "WARNING" "$hot_gpu_count unique GPUs exceeded 85°C temperature threshold during testing"
    fi
    
    echo -e "\n" >> "$summary_file"
    echo "$current_date" >> "$summary_file"
    echo "DeviceName: $(hostname)" >> "$summary_file"
    echo "InstantaneousTemperature: ${last_temp:-N/A} C" >> "$summary_file"
    echo "PeakTemperature: ${highest_temp:-0} C" >> "$summary_file"
    echo "PeakDate: $(date -u '+%Y-%m-%dT%H:%M:%S-06:00')" >> "$summary_file"
    echo "AvgTemperature: ${avg_temp:-N/A} C" >> "$summary_file"
    
    if [[ "$highest_temp" =~ ^[0-9]+([.][0-9]+)?$ && $(echo "$highest_temp >= 85" | bc -l) -eq 1 ]]; then
        echo "Temperature summary generated at $summary_file (HIGH TEMPERATURES DETECTED)"
        display_message "WARNING" "Temperature summary generated (HIGH TEMPERATURES DETECTED in $summary_file)"
    else
        echo "Temperature summary generated at $summary_file"
         display_message "INFO" "Temperature summary generated at $summary_file"
    fi
    
    # No need for hot_gpus.txt file anymore
    # rm -f "${LOGDIR}/hot_gpus.txt"
    return 0 # Return success even if warnings occurred
}

# Function to check for running GPU processes
check_running_gpu_processes() {
    display_message "INFO" "Checking for running GPU processes..."
    
    # Check if nvidia-smi is available
    if ! command -v nvidia-smi &> /dev/null; then
        display_message "ERROR" "nvidia-smi command not found, cannot check for running processes"
        update_context_file "Warning" "Cannot check for running GPU processes - nvidia-smi not found"
        return 0
    fi
    
    # Get running processes using GPUs
    local gpu_processes=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)
    
    if [ -z "$gpu_processes" ]; then
        display_message "INFO" "No running GPU processes detected"
        update_context_file "GPU Process Check" "No running GPU processes detected"
        # Proceed to check container services even if no GPU processes found
    else
        # Display running processes
        display_message "WARNING" "Running GPU processes detected that may interfere with testing:"
        echo "-------------------------------------------"
        echo "PID, Process Name, GPU Memory Usage"
        echo "$gpu_processes"
        echo "-------------------------------------------"
        
        # Display detailed process information
        echo "Detailed process information:"
        echo "$gpu_processes" | while IFS=',' read -r pid process_name memory_usage; do
            pid=$(echo "$pid" | tr -d ' ')
            # Step 1: Check if PID is non-empty
            if [[ -n "$pid" ]]; then
                # Step 2: Check if it's a positive integer using grep, checking exit code
                if echo "$pid" | grep -qE '^[1-9][0-9]*$'; then
                    # If grep succeeds (exit code 0), proceed
                    echo "Process: $process_name (PID: $pid)"
                    ps -o user,start_time,etime,cmd -p "$pid" 2>/dev/null | sed 's/^/  /' || echo "  Unable to get details for PID $pid"
                    echo ""
                # else # Optional: Handle invalid PID format if needed
                #    display_message "WARNING" "Invalid PID format detected in nvidia-smi output: '$pid'"
                fi
            fi
        done # End of the display loop
        
        update_context_file "Running GPU Processes" "Detected running GPU processes that may interfere with testing: $gpu_processes"
        
        # Ask user whether to kill these processes
        echo ""
        local choice="N"
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            if [[ "${AUTO_KILL_GPU_PROCESSES:-false}" == "true" ]]; then
                # Auto-kill flag is set - proceed to kill
                display_message "WARNING" "Running in non-interactive mode with --auto-kill-gpu enabled."
                display_message "INFO" "Automatically killing GPU processes..."
                choice="y"
            else
                # No auto-kill flag - abort with helpful message
                display_message "WARNING" "Running in non-interactive mode. GPU processes detected - aborting."
                display_message "ERROR" "GPU processes must be killed before running thermal test."
                display_message "INFO" "To auto-kill GPU processes, use: --auto-kill-gpu flag"
                display_message "INFO" "Or use --auto-all to auto-handle both services and GPU processes"
                update_context_file "Process Check" "Aborting (non-interactive mode with running GPU processes)"
                exit 10
            fi
        else
            read -p "Kill running GPU processes and continue with test? (N/y): " choice
        fi
        
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            display_message "INFO" "Attempting to terminate running GPU processes using pkill..."
            local unique_process_names=()
            
            # Extract unique process names (column 2)
            unique_process_names=($(echo "$gpu_processes" | cut -d ',' -f 2 | tr -d ' ' | sort -u))

            if [ ${#unique_process_names[@]} -gt 0 ]; then
                for process_name in "${unique_process_names[@]}"; do
                    # Ensure process name is not empty before trying to kill
                    if [ -n "$process_name" ]; then
                        display_message "INFO" "Running: pkill -9 -f '$process_name'"
                        if pkill -9 -f "$process_name"; then
                            display_message "SUCCESS" "pkill command succeeded for process name '$process_name' (may have killed 0 or more instances)"
                        else
                            # pkill returns non-zero if no processes were matched/killed, which isn't necessarily an error here.
                            display_message "INFO" "pkill command finished for process name '$process_name' (may indicate no running instances found)"
                        fi
                    fi
                done
            else
                display_message "WARNING" "Could not extract process names to kill."
            fi

            sleep 3 # Give processes time to terminate

            # Verify all processes are terminated
            local remaining_processes=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null)
            if [ -n "$remaining_processes" ]; then
                display_message "WARNING" "Some GPU processes are still running after termination attempt:"
                echo "$remaining_processes"
                update_context_file "Process Termination" "Failed to terminate all GPU processes: $remaining_processes"
                
                if [[ "$NON_INTERACTIVE" == "true" ]]; then
                    display_message "ERROR" "GPU processes still running in non-interactive mode - aborting."
                    update_context_file "Process Check" "Aborting (non-interactive mode with persistent GPU processes)"
                    exit 10
                fi
                read -p "Continue with test despite running processes? (N/y): " continue_choice
                if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
                    display_message "ERROR" "Exiting as requested due to running GPU processes"
                    update_context_file "Process Check" "User exited due to running GPU processes"
                    exit 10  # Error code for GPU process conflict
                fi
            else
                display_message "SUCCESS" "Successfully terminated all GPU processes"
                update_context_file "Process Termination" "Successfully terminated all GPU processes"
            fi
        else
            # User chose not to kill processes
            display_message "ERROR" "Exiting as requested due to running GPU processes"
            update_context_file "Process Check" "User exited due to running GPU processes"
            exit 10  # Error code for GPU process conflict
        fi
    fi # End of check for gpu_processes

    # --- Check for container/kubernetes services --- 
    display_message "INFO" "Checking for running container/Kubernetes services (kube, containerd, docker)..."
    local conflicting_services=()
    local service_details=""
    
    # Check systemd services
    if command -v systemctl &> /dev/null; then
        for service_pattern in kube containerd docker; do
            # Find active services matching the pattern
            local active_services=$(systemctl list-units --type=service --state=running | grep -E "${service_pattern}[-.@]?" | awk '{print $1}')
            if [ -n "$active_services" ]; then
                for service in $active_services; do
                    conflicting_services+=("$service")
                    local service_status=$(systemctl status "$service" | head -n 5) # Get first 5 lines of status
                    service_details+="Service: $service\nStatus:\n${service_status}\n---\n"
                done
            fi
        done
    else
        display_message "WARNING" "systemctl not found, cannot perform systemd service checks."
        update_context_file "Container Service Check" "systemctl not found, skipped service check."
    fi

    # Check for processes if systemctl isn't available or as a fallback
    if [ ${#conflicting_services[@]} -eq 0 ] && ! command -v systemctl &> /dev/null; then
         display_message "INFO" "Checking processes for container/kubernetes keywords..."
         local process_check=$(ps aux | grep -E 'kube|containerd|docker' | grep -v grep)
         if [ -n "$process_check" ]; then
            conflicting_services+=("Potential conflicting processes found")
            service_details+="Processes found matching keywords (kube, containerd, docker):\n${process_check}\n---\n"
         fi
    fi

    # If conflicting services/processes are found
    if [ ${#conflicting_services[@]} -gt 0 ]; then
        display_message "WARNING" "Running container/Kubernetes services or processes detected that may interfere with testing:"
        echo "-------------------------------------------"
        printf '%s\n' "${conflicting_services[@]}"
        echo "-------------------------------------------"
        echo "Service/Process Details:"
        echo -e "$service_details"
        
        update_context_file "Container Service Check" "Detected potentially conflicting services/processes: ${conflicting_services[*]}"
        
        # Non-interactive mode handling
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            if [[ "${AUTO_STOP_SERVICES:-false}" == "true" ]]; then
                # Auto-stop services flag is set - attempt to stop them
                display_message "WARNING" "Running in non-interactive mode with --auto-stop-services enabled."
                display_message "INFO" "Attempting to automatically stop container services..."
                
                if command -v systemctl &> /dev/null; then
                    local stop_failures=0
                    local stopped_services=()
                    for service in "${conflicting_services[@]}"; do
                        if systemctl list-units --type=service --all | grep -q "^${service}"; then
                            display_message "INFO" "Stopping service: $service"
                            if systemctl stop "$service" 2>/dev/null; then
                                echo "  ✓ Stopped $service"
                                stopped_services+=("$service")
                            else
                                echo "  ✗ Failed to stop $service"
                                stop_failures=$((stop_failures + 1))
                            fi
                        fi
                    done
                    
                    sleep 3 # Give services time to stop
                    
                    # Verify services are stopped
                    local still_running=0
                    for service in "${conflicting_services[@]}"; do
                        if systemctl list-units --type=service --all | grep -q "^${service}" && systemctl is-active --quiet "$service"; then
                            display_message "WARNING" "Service $service is still running after stop attempt."
                            still_running=$((still_running + 1))
                        fi
                    done
                    
                    if [ $still_running -gt 0 ]; then
                        display_message "ERROR" "Failed to stop all container services. Aborting."
                        update_context_file "Container Service Check" "Failed to auto-stop services in non-interactive mode"
                        exit 11
                    else
                        display_message "SUCCESS" "Successfully stopped container services."
                        update_context_file "Container Service Stop" "Auto-stopped services: ${conflicting_services[*]}"
                        # Save stopped services list for restart after test
                        if [[ -n "${LOGDIR:-}" ]]; then
                            printf '%s\n' "${stopped_services[@]}" > "${LOGDIR}/stopped_services.txt"
                        fi
                    fi
                else
                    display_message "ERROR" "systemctl not found - cannot auto-stop services. Aborting."
                    update_context_file "Container Service Check" "Aborting (systemctl not available for auto-stop)"
                    exit 11
                fi
            else
                # No auto-stop flag - abort with helpful message
                display_message "WARNING" "Running in non-interactive mode. Container services detected - aborting."
                display_message "ERROR" "Container services (kubelet, containerd, docker) must be stopped before thermal test."
                display_message "INFO" "To auto-stop services, use: --auto-stop-services flag"
                display_message "INFO" "Or manually stop with: sudo systemctl stop kubelet containerd docker"
                update_context_file "Container Service Check" "Aborting (non-interactive mode with running services)"
                exit 11
            fi
            # Continue if we get here (services were stopped successfully)
            return 0
        fi
        
        # Ask user if they want to attempt stopping services (if systemctl exists)
        if command -v systemctl &> /dev/null; then
            read -p "Attempt to STOP these services and continue? (N/y): " stop_choice
            if [[ "$stop_choice" == "y" || "$stop_choice" == "Y" ]]; then
                display_message "INFO" "Attempting to stop detected services..."
                local stop_failures=0
                for service in "${conflicting_services[@]}"; do
                    # Check if it's a real service name before trying to stop
                    if systemctl list-units --type=service --all | grep -q "^${service}"; then
                        display_message "INFO" "Stopping service: $service"
                        if systemctl stop "$service"; then
                            echo "Successfully stopped $service"
                        else
                            echo "Failed to stop $service"
                            stop_failures=$((stop_failures + 1))
                        fi
                    else
                         echo "Skipping non-service item: $service" # Handles the process check case
                    fi
                done
                
                sleep 3 # Give services time to stop

                # Verify services are stopped
                local still_running=0
                 for service in "${conflicting_services[@]}"; do
                    if systemctl list-units --type=service --all | grep -q "^${service}" && systemctl is-active --quiet "$service"; then
                         display_message "WARNING" "Service $service is still running after stop attempt."
                         still_running=$((still_running + 1))
                    fi
                 done

                if [ $still_running -gt 0 ]; then
                    update_context_file "Container Service Stop" "Failed to stop all detected services."
                    read -p "Continue test despite running container services? (N/y): " continue_anyway
                     if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
                         display_message "ERROR" "Exiting as requested due to running container services."
                         update_context_file "Container Service Check" "User exited due to running container services after failed stop attempt."
                         exit 11 # New error code for container service conflict
                     fi
                     display_message "WARNING" "Continuing test despite running container services after failed stop attempt."
                     update_context_file "Container Service Check" "User chose to continue despite running container services after failed stop attempt."
                else
                    display_message "SUCCESS" "Successfully stopped detected container services."
                    update_context_file "Container Service Stop" "Successfully stopped detected services: ${conflicting_services[*]}"
                fi
            else
                # User chose not to stop services
                 read -p "Continue test despite running container services? (N/y): " continue_anyway_no_stop
                 if [[ "$continue_anyway_no_stop" != "y" && "$continue_anyway_no_stop" != "Y" ]]; then
                     display_message "ERROR" "Exiting as requested due to running container services."
                     update_context_file "Container Service Check" "User exited due to running container services (chose not to stop)."
                     exit 11 # New error code for container service conflict
                 fi
                 display_message "WARNING" "Continuing test despite running container services (user chose not to stop)."
                 update_context_file "Container Service Check" "User chose to continue despite running container services (did not attempt stop)."
            fi
        else 
            # systemctl not available, cannot attempt stop - just ask to continue
             read -p "Continue test despite potentially running container processes? (N/y): " continue_no_sysctl
             if [[ "$continue_no_sysctl" != "y" && "$continue_no_sysctl" != "Y" ]]; then
                 display_message "ERROR" "Exiting as requested due to potentially running container processes."
                 update_context_file "Container Service Check" "User exited due to potentially running container processes (systemctl unavailable)."
                 exit 11 # New error code for container service conflict
             fi
             display_message "WARNING" "Continuing test despite potentially running container processes (systemctl unavailable)."
             update_context_file "Container Service Check" "User chose to continue despite potentially running container processes (systemctl unavailable)."
        fi
    else
        display_message "INFO" "No running container/Kubernetes services detected."
        update_context_file "Container Service Check" "No conflicting container/Kubernetes services or processes detected."
    fi
    
    return 0
}

# Function to collect nvidia bug report
collect_nvidia_bug_report() {
    display_message "INFO" "Collecting NVIDIA bug report..."
    local hostname=$(hostname -s)
    
    # Get service tag using improved method
    local service_tag=$(get_service_tag)
    
    # Use the requested format: nvidia-bug-report-{HOSTNAME}-{SERVICETAG}
    local output_file="${LOGDIR}/nvidia-bug-report-${hostname}-${service_tag}"
    
    # Check if nvidia-bug-report.sh exists
    if ! command -v nvidia-bug-report.sh &> /dev/null; then
        display_message "WARNING" "nvidia-bug-report.sh not found, attempting to use full path"
        local bug_report_cmd=""
        
        # Try several possible locations
        local nvidia_smi_dir=""
        if command -v nvidia-smi &> /dev/null; then
            nvidia_smi_dir=$(dirname "$(which nvidia-smi)")
        fi
        local nvidia_bug_path="${nvidia_smi_dir}/nvidia-bug-report.sh"
        
        for path in "/usr/bin/nvidia-bug-report.sh" "/usr/local/bin/nvidia-bug-report.sh" "$nvidia_bug_path"; do
            if [ -f "$path" ]; then
                bug_report_cmd="$path"
                break
            fi
        done
        
        if [ -z "$bug_report_cmd" ]; then
            display_message "ERROR" "Could not find nvidia-bug-report.sh script"
            update_context_file "NVIDIA Bug Report" "Failed to locate nvidia-bug-report.sh script"
            return 1
        fi
    else
        bug_report_cmd="nvidia-bug-report.sh"
    fi
    
    # Try to run the bug report script with error handling
    display_message "INFO" "Running $bug_report_cmd -o $output_file"
    if ! $bug_report_cmd -o "$output_file" 2>/dev/null; then
        display_message "WARNING" "nvidia-bug-report.sh command failed, trying without output specification"
        
        # Try running without output parameter
        if ! $bug_report_cmd 2>/dev/null; then
            display_message "ERROR" "Failed to collect NVIDIA bug report"
            update_context_file "NVIDIA Bug Report" "Failed to run bug report collection command"
            return 1
        fi
        
        # If running without -o succeeded, try to find and move the file
        local default_report=$(find /tmp -maxdepth 1 -name "nvidia-bug-report*.log.gz" -type f -mmin -2 2>/dev/null || find /tmp -maxdepth 1 -name "nvidia-bug-report*.gz" -type f -mmin -2 2>/dev/null)
        if [ -n "$default_report" ]; then
            cp "$default_report" "${output_file}.log.gz"
            display_message "INFO" "Copied default report from $default_report to ${output_file}.log.gz"
        else
            display_message "ERROR" "Could not find generated bug report"
            update_context_file "NVIDIA Bug Report" "Bug report command ran but couldn't locate output file"
            return 1
        fi
    fi
    
    # Wait for file to be created (up to 30 seconds)
    local max_wait=30
    local count=0
    local found_file=""
    
    while [ -z "$found_file" ] && [ $count -lt $max_wait ]; do
        sleep 1
        ((count++))
        
        # Check for both possible extensions
        if [ -f "${output_file}.log.gz" ]; then
            found_file="${output_file}.log.gz"
        elif [ -f "${output_file}.gz" ]; then
            found_file="${output_file}.gz"
        fi
        
        if [ $((count % 5)) -eq 0 ]; then
            display_message "INFO" "Waiting for bug report to be generated... ($count/$max_wait seconds)"
        fi
    done
    
    if [ -n "$found_file" ]; then
        # Rename file to ensure correct extension (.gz)
        if [[ "$found_file" == *.log.gz ]]; then
            local new_name="${output_file}.gz"
            mv "$found_file" "$new_name"
            found_file="$new_name"
        fi
        display_message "SUCCESS" "NVIDIA bug report collected successfully at $found_file"
        chmod 644 "$found_file"
        update_context_file "NVIDIA Bug Report" "Successfully collected bug report at $found_file"
        return 0
    else
        # One more attempt to find the file by searching the directory
        local search_pattern="nvidia-bug-report*.gz"
        local search_result=$(find "${LOGDIR}" -name "$search_pattern" -type f -mmin -2 2>/dev/null)
        
        if [ -n "$search_result" ]; then
            # If found a file with old name format, rename it to match the standardized name
            local new_name="${output_file}.gz"
            mv "$search_result" "$new_name"
            display_message "SUCCESS" "NVIDIA bug report found and renamed to standardized format: $new_name"
            chmod 644 "$new_name"
            update_context_file "NVIDIA Bug Report" "Successfully collected bug report and renamed to: $new_name"
            return 0
        else
            display_message "ERROR" "Failed to collect NVIDIA bug report - file not created"
            update_context_file "NVIDIA Bug Report" "Failed to generate bug report file"
            return 1
        fi
    fi
}

# Function to kill background PIDs cleanly
# Pass "quiet" as first argument to suppress messages
kill_background_pids() {
    local quiet="${1:-}"
    [[ "$quiet" != "quiet" ]] && display_message "INFO" "Attempting to clean up background processes..."
    local pids_to_kill=()
    # Add PIDs to an array if they are set
    [ -n "${WORKLOAD_PID:-}" ] && pids_to_kill+=("$WORKLOAD_PID")
    [ -n "${NVIDIA_SMI_PID:-}" ] && pids_to_kill+=("$NVIDIA_SMI_PID")
    [ -n "${BMC_PID:-}" ] && pids_to_kill+=("$BMC_PID")

    if [ ${#pids_to_kill[@]} -eq 0 ]; then
        [[ "$quiet" != "quiet" ]] && display_message "INFO" "No background PIDs were recorded to kill."
        return 0
    fi

    for pid_val in "${pids_to_kill[@]}"; do
        if ps -p "$pid_val" > /dev/null; then # Check if process exists
            display_message "INFO" "Sending SIGTERM to PID: $pid_val"
            kill -TERM "$pid_val" 2>/dev/null
            sleep 0.5 # Give it a moment to terminate gracefully
            if ps -p "$pid_val" > /dev/null; then # Check again
                display_message "WARNING" "PID $pid_val did not terminate with SIGTERM, sending SIGKILL."
                kill -KILL "$pid_val" 2>/dev/null
                sleep 0.5 # Give SIGKILL a moment
                if ps -p "$pid_val" > /dev/null; then # Final check
                    display_message "ERROR" "Failed to kill PID $pid_val even with SIGKILL."
                else
                    display_message "INFO" "PID $pid_val successfully killed with SIGKILL."
                fi
            else
                display_message "INFO" "PID $pid_val successfully terminated with SIGTERM."
            fi
        else
            display_message "INFO" "PID $pid_val not found or already terminated."
        fi
    done
    # Clear the global PID variables after attempting to kill
    WORKLOAD_PID=""
    NVIDIA_SMI_PID=""
    BMC_PID=""
    display_message "INFO" "Background process cleanup attempt finished."
}

# Main function
main() {    
    setup_log_directory
    display_message "INFO" "Created log directory at ${LOGDIR}"
    update_context_file "Setup" "Created log directory at ${LOGDIR}"
    
    get_configuration
    update_context_file "Configuration" "Mode: ${REMOTE_MODE}"
    
    detect_os
    display_message "INFO" "Detected OS: ${OS_NAME} ${OS_VERSION}"
    update_context_file "OS Detection" "Detected OS: ${OS_NAME} ${OS_VERSION}"
    
    # Check packages and update context
    check_packages
    local pkg_result=$?
    if [ $pkg_result -eq 0 ]; then
        display_message "SUCCESS" "All required packages are available and DCGM service is running"
        update_context_file "Package Check" "All required packages are available and DCGM service is running"
    else
        display_message "WARNING" "Some issues with packages or DCGM service, but continuing as requested"
        update_context_file "Package Check" "Some issues with packages or DCGM service, but continuing as requested by user"
    fi
    
    setup_credentials_and_altitude
    display_message "INFO" "Credentials and altitude set up successfully"
    update_context_file "Credentials/Altitude" "Credentials and altitude ($altitude_ft ft) set up successfully"
    
    # Check SupportAssist EULA status (from dcgmprofrunner.sh v2.6)
    local eula_result
    check_supportassist_eula
    eula_result=$?
    if [ $eula_result -eq 1 ]; then
        # EULA not accepted - check if running non-interactively
        if [[ "$NON_INTERACTIVE" == "true" ]] || [ ! -t 0 ]; then
            # Non-interactive mode (multi-node execution) - auto-continue with warning
            display_message "WARNING" "EULA not accepted but running non-interactively. Proceeding anyway..."
            display_message "WARNING" "(SupportAssist TSR Collection may fail)"
            update_context_file "EULA Warning" "EULA not accepted, auto-continuing (non-interactive mode)"
        else
            # Interactive mode - ask user
            read -p "Do you want to exit now? (Y/N): " eula_choice
            if [[ "$eula_choice" =~ ^[Yy]$ ]]; then
                display_message "INFO" "Exiting script due to EULA not accepted."
                exit 1
            else
                display_message "WARNING" "Proceeding anyway... (SupportAssist TSR Collection may fail)"
                update_context_file "EULA Warning" "Continuing despite EULA not being accepted"
            fi
        fi
    fi
    
    # Check for running GPU processes before continuing
    check_running_gpu_processes
    display_message "INFO" "GPU process check completed"
    
    # Clear existing TSR jobs and handle errors
    local tsr_clear_result=0
    clear_existing_tsr_jobs
    tsr_clear_result=$?
    
    if [ $tsr_clear_result -eq 0 ]; then
        update_context_file "TSR Jobs" "Successfully cleared or no existing TSR jobs found"
    else
        update_context_file "TSR Jobs Warning" "Proceeding with existing TSR jobs still in the queue"
    fi
    
    display_message "INFO" "Starting thermal test - this will take approximately $(($THERMAL_DURATION/60)) minutes"
    run_thermal_test
    display_message "SUCCESS" "Completed thermal test data collection phase"
    update_context_file "Thermal Test" "Completed thermal test data collection phase"

    # Process BMC data and merge logs
    process_bmc_data
    local process_result=$?
    if [ $process_result -ne 0 ]; then
        display_message "ERROR" "Failed to process and merge BMC data. Skipping failure check and summary generation."
        update_context_file "Error" "Failed to process BMC data. Aborting further analysis."
        # Create marker so exit handler knows core test ran
        touch "${LOGDIR}/test_completion_marker"
        # Set specific exit code for processing failure
        echo "7" > "${LOGDIR}/final_exit_code"
        exit 7 # Exit immediately with code 7
    fi
    # Find the Dell-format thermal results file
    local final_metrics_file=$(find "${LOGDIR}" -maxdepth 1 -name "thermal_results.*.csv" -type f | head -1)

    # Create marker *after* successful data collection/processing
    touch "${LOGDIR}/test_completion_marker" 
    local final_exit_code=0 # Default to success - data collection complete
    
    # NOTE: Failure detection removed as of v2.6 alignment
    # Dell now uses an internal NVIDIA tool to interpret results
    # The collected data (CSV, TSR, logs) must be sent to Dell for RMA determination
    display_message "INFO" "Data collection complete. Results must be submitted to Dell for thermal analysis."
    update_context_file "Data Collection" "Complete - submit to Dell for RMA determination"
    
    echo "$final_exit_code" > "${LOGDIR}/final_exit_code"

    # Continue with summary and bug report generation regardless of failure check outcome
    # These functions are now more robust and return 0 unless catastrophic
    # NOTE: Dell v2.6 does NOT generate these extra files:
    # - temperature_summary.txt (VP addition - skipped for Dell compatibility)
    # - nvidia-bug-report.gz (VP addition - skipped for Dell compatibility)
    # Uncomment these if VP-specific diagnostics are needed:
    # display_message "INFO" "Generating temperature summary"
    # generate_temp_summary
    # display_message "INFO" "Collecting NVIDIA bug report"
    # collect_nvidia_bug_report

    # Create a zip archive of the log directory
    display_message "INFO" "Creating final zip archive of test results"
    zip_log_directory || {
        display_message "WARNING" "Failed to create zip archive, but continuing with test completion"
        update_context_file "Archive Warning" "Failed to create zip archive, continuing with original directory"
    }

    # Final status message determined by exit handler based on final_exit_code file
    display_message "INFO" "All test results are saved in ${LOGDIR}.zip or ${LOGDIR} if zipping failed"
    
    # Before exiting, make sure to provide correct path to results for later reference
    if [ -f "${LOGDIR}.zip" ] && [ ! -d "${LOGDIR}" ]; then
        # The directory has been archived and removed
        FINAL_RESULTS_PATH="${LOGDIR}.zip"
    else
        # Either the archive failed or hasn't been created yet
        FINAL_RESULTS_PATH="${LOGDIR}"
    fi
    # Store the path for use by the exit handler
    echo "${FINAL_RESULTS_PATH}" > "${LOGDIR_BASE}/last_results_path"
    
    display_message "INFO" "Script finalizing... Exit code determined by test result: $final_exit_code"

    exit $final_exit_code # Exit with the code determined by check_failures primarily
}

# =============================================================================
# MULTI-NODE EXECUTION MODE
# =============================================================================
# When run with --nodes or --multi flag, this script acts as a controller
# that deploys itself to multiple remote nodes, runs the test, and collects results.

MULTI_NODE_MODE=false
NODE_LIST=""
SSH_USER="${SSH_USER:-vpsupport}"
REPORTS_DIR="${HOME}/Reports/thermal-diagnostics"
PARALLEL_JOBS=3  # Run tests on 3 nodes at a time (thermal tests are resource-intensive)
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# Preserve exported values from wrapper, default to false if not set
AUTO_STOP_SERVICES="${AUTO_STOP_SERVICES:-false}"
AUTO_KILL_GPU_PROCESSES="${AUTO_KILL_GPU_PROCESSES:-false}"

# Use sshv command (like start-node-toolkit.sh)
SSHV_COMMAND="sshv"
# SSH options for remote operations (array format for proper quoting)
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3)
SCP_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Function to check if sshv is available
check_sshv() {
    if ! command -v "$SSHV_COMMAND" &> /dev/null; then
        echo -e "${RED}Error: '$SSHV_COMMAND' not found in your PATH.${NC}"
        echo -e "${YELLOW}Please install SSHV first or ensure it's in your PATH.${NC}"
        echo -e "${DIM}SSHV is required for authenticated SSH connections to Voltage Park nodes.${NC}"
        return 1
    fi
    return 0
}

# Function to display multi-node help
show_multinode_help() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  GPU Thermal Diagnostics Tool - Version ${SCRIPT_VERSION} (${SCRIPT_TAG:-latest})"
    echo "  Based on Dell dcgmprofrunner.sh v2.6"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "DESCRIPTION:"
    echo "  This tool runs Dell's GPU thermal stress test (dcgmprofrunner v2.6) on one or"
    echo "  more nodes, collecting thermal data for Dell RMA analysis. It wraps the Dell"
    echo "  script with multi-node orchestration, automatic service handling, and proper"
    echo "  output packaging for Dell submission."
    echo ""
    echo "  The test runs for ~15 minutes per node and collects:"
    echo "    - GPU temperature, power, clock speeds via nvidia-smi"
    echo "    - BMC inlet temperature, air pressure, fan PWM"
    echo "    - SupportAssist Technical Support Report (TSR)"
    echo "    - NVIDIA bug report"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "USAGE:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  $0 [OPTIONS]"
    echo ""
    echo "MODES:"
    echo "  (no args)         Interactive menu mode - guided wizard for all options"
    echo "  --local           Run thermal test on THIS machine (requires root)"
    echo "  --nodes \"...\"     Run on specified remote nodes via sshv"
    echo "  --nodes-file FILE Run on nodes listed in a file (one per line)"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "MULTI-NODE OPTIONS:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  --nodes \"IP1 IP2 ...\"   Space-separated list of node IPs or hostnames"
    echo "                          Example: --nodes \"10.0.0.1 10.0.0.2 10.0.0.3\""
    echo ""
    echo "  --nodes-file FILE       Read nodes from a file (one IP/hostname per line)"
    echo "                          Lines starting with # are ignored"
    echo "                          Example: --nodes-file /path/to/nodes.txt"
    echo ""
    echo "  --user USER             SSH username for remote connections (default: vpsupport)"
    echo "                          Must have sudo access on remote nodes"
    echo ""
    echo "  --dc-name NAME          Datacenter/site name for the rollup zip file"
    echo "                          Used in output naming: NAME-YYYYMMDD-HHMMSS.zip"
    echo "                          Examples: iad1-c2, ftw1-a1, str1-b3, pyl1-c1"
    echo "                          If not provided, will prompt interactively"
    echo ""
    echo "  --altitude FEET         Altitude of test site in feet (affects air pressure calc)"
    echo "                          Common values: FTW1=653, STR1=289, PYL1=220, ALN1=656"
    echo "                          If not provided, will prompt with site selection menu"
    echo ""
    echo "  --reports-dir DIR       Directory to save results (default: ~/Reports/thermal-diagnostics)"
    echo ""
    echo "  --parallel N            Max parallel jobs (default: 3) - not fully implemented"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "AUTO-HANDLING OPTIONS:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  IMPORTANT: Thermal tests require exclusive GPU access. If GPU processes or"
    echo "  container services are running, the test will fail. Use these flags to"
    echo "  automatically handle these on remote nodes:"
    echo ""
    echo "  --auto-stop-services    Automatically stop container services before test:"
    echo "                          - kubelet (Kubernetes)"
    echo "                          - containerd"
    echo "                          - docker"
    echo "                          Services are restarted after test completion."
    echo "                          Without this flag, test ABORTS if services are running."
    echo ""
    echo "  --auto-kill-gpu         Automatically kill GPU processes before test:"
    echo "                          - ollama, python, jupyter, tensorflow, pytorch, etc."
    echo "                          Without this flag, test ABORTS if GPU processes found."
    echo ""
    echo "  --auto-all              Enable BOTH --auto-stop-services and --auto-kill-gpu"
    echo "                          Recommended for unattended batch runs."
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "OTHER OPTIONS:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  --help, -h              Show this help message"
    echo "  --version, -V           Show version information"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "OUTPUT FORMAT:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Multi-node runs produce a rollup zip file for Dell submission:"
    echo ""
    echo "    ~/Reports/thermal-diagnostics/"
    echo "    ├── iad1-c2-20260116-143000/          <- Folder with individual node zips"
    echo "    │   ├── g329-7871FZ3.zip              <- Node zip (hostname-ServiceTag.zip)"
    echo "    │   │   └── dcgmprof-XXXXX/           <- Dell's original structure intact"
    echo "    │   │       ├── thermal_results.*.csv <- Main thermal data"
    echo "    │   │       ├── TSR_XXXXX_*.zip       <- SupportAssist report"
    echo "    │   │       ├── dcgmproftester.log    <- Stress test output"
    echo "    │   │       ├── tensor_active_*.results <- Per-GPU results (8 files)"
    echo "    │   │       └── (total ~13 files per node)"
    echo "    │   ├── g330-DV42FZ3.zip"
    echo "    │   └── ..."
    echo "    └── iad1-c2-20260116-143000.zip       <- SUBMIT THIS TO DELL"
    echo ""
    echo "  The rollup zip contains individual node zips with Dell's original"
    echo "  dcgmprof directory structure intact - ready for Dell's parser."
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "EXAMPLES:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  # Interactive menu (recommended for first-time users)"
    echo "  $0"
    echo ""
    echo "  # Full automated run on multiple nodes"
    echo "  $0 --nodes \"10.0.0.1 10.0.0.2 10.0.0.3\" \\"
    echo "     --dc-name iad1-c2 \\"
    echo "     --altitude 656 \\"
    echo "     --auto-all"
    echo ""
    echo "  # Using a nodes file"
    echo "  $0 --nodes-file nodes.txt --dc-name ftw1-a1 --altitude 653 --auto-all"
    echo ""
    echo "  # Run on local machine only"
    echo "  sudo $0 --local"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "REQUIREMENTS:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Local execution (--local):"
    echo "    - Root/sudo access"
    echo "    - NVIDIA drivers and nvidia-smi"
    echo "    - DCGM (datacenter-gpu-manager) - auto-installed if missing"
    echo "    - ipmitool for BMC data"
    echo "    - racadm for iDRAC communication"
    echo ""
    echo "  Multi-node execution:"
    echo "    - sshv command available (Voltage Park SSH wrapper)"
    echo "    - SSH key access to remote nodes"
    echo "    - Remote nodes must have above requirements"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "NOTES:"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  - Test duration: ~20-25 minutes per node (including download)"
    echo "  - Output size: ~25-35 MB per node"
    echo "  - Dell v2.6 does NOT provide pass/fail - results must be submitted to Dell"
    echo "  - SupportAssist EULA must be accepted on iDRAC before running"
    echo "  - For best results, run during maintenance window with no GPU workloads"
    echo ""
}

# Function to run thermal test on a single remote node
run_on_remote_node() {
    local node="$1"
    local altitude="$2"
    local target_dir="${3:-$REPORTS_DIR}"  # Use rollup_dir if provided, else REPORTS_DIR
    local status_file="${4:-}"  # Optional: status file to update for progress tracking
    local timestamp=$(date +%Y%m%d-%H%M%S)

    echo -e "\n${GREEN}[NODE: $node]${NC} Starting thermal diagnostics..."

    # Get hostname and service tag from remote node using sshv
    local remote_hostname
    remote_hostname=$($SSHV_COMMAND "$SSH_USER@$node" "hostname -s" 2>/dev/null | tr -d '\r')
    [[ -z "$remote_hostname" ]] && remote_hostname="$node"

    local service_tag
    service_tag=$($SSHV_COMMAND "$SSH_USER@$node" "sudo racadm getsysinfo 2>/dev/null | grep 'Service Tag' | awk -F= '{print \$2}' | tr -d '[:space:]'" 2>/dev/null | tr -d '\r')
    [[ -z "$service_tag" ]] && service_tag="UNKNOWN"
    
    # Output zip name: hostname-ServiceTag.zip (Dell format - each node is a zip)
    local node_zip_name="${remote_hostname}-${service_tag}.zip"
    local node_zip_path="${target_dir}/${node_zip_name}"
    
    # Temp folder for downloading (will be zipped then deleted)
    local node_dir="${target_dir}/.tmp-${remote_hostname}-${service_tag}"
    mkdir -p "$node_dir"
    
    echo -e "${CYAN}[NODE: $node]${NC} Hostname: $remote_hostname, Service Tag: $service_tag"
    echo -e "${CYAN}[NODE: $node]${NC} Results will be saved to: $node_dir"
    
    # Upload the script to the remote node using sshv scp
    echo -e "${YELLOW}[NODE: $node]${NC} Uploading thermal script..."
    local upload_error
    upload_error=$($SSHV_COMMAND scp $SCP_OPTIONS "$SCRIPT_PATH" "$SSH_USER@$node:/tmp/thermal_diag.sh" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[NODE: $node]${NC} Failed to upload script"
        echo -e "${DIM}    Error: $(echo "$upload_error" | head -2 | tr '\n' ' ')${NC}"
        echo "FAILED: Could not upload script - $upload_error" > "$node_dir/error.log"
        return 1
    fi
    
    # Create a wrapper script that sets altitude and runs non-interactively
    local remote_wrapper="/tmp/run_thermal_${timestamp}.sh"
    $SSHV_COMMAND "$SSH_USER@$node" "cat > $remote_wrapper" << EOF
#!/bin/bash
export altitude_ft=$altitude
export NON_INTERACTIVE=true
export AUTO_STOP_SERVICES=${AUTO_STOP_SERVICES}
export AUTO_KILL_GPU_PROCESSES=${AUTO_KILL_GPU_PROCESSES}
# Run the thermal script in local mode (non-interactive)
sudo -E bash /tmp/thermal_diag.sh --local
EOF
    
    $SSHV_COMMAND "$SSH_USER@$node" "chmod +x $remote_wrapper" 2>/dev/null
    
    # Run the test on the remote node
    echo -e "${YELLOW}[NODE: $node]${NC} Running thermal test (this will take ~20-25 minutes)..."
    local test_output
    # Use simpler sshv invocation without SSH_OPTIONS array (sshv handles auth internally)
    test_output=$($SSHV_COMMAND "$SSH_USER@$node" "sudo bash $remote_wrapper" 2>&1)
    local test_status=$?
    
    # Note: test_output is logged remotely, not saved locally
    # Dell only needs the dcgmprof-* folder contents
    
    if [[ $test_status -ne 0 ]]; then
        echo -e "${RED}[NODE: $node]${NC} Test completed with exit code: $test_status"
    else
        echo -e "${GREEN}[NODE: $node]${NC} Test completed successfully"
    fi
    
    # Update status to "downloading" if status file is provided
    [[ -n "$status_file" ]] && echo "downloading" > "$status_file"
    
    # Download entire TDAS folder from remote node
    echo -e "${YELLOW}[NODE: $node]${NC} Downloading TDAS results folder..."
    
    # Make TDAS folder readable
    $SSHV_COMMAND "$SSH_USER@$node" "sudo chmod -R 755 /root/TDAS 2>/dev/null" 2>/dev/null
    
    # Get the most recent results directory/zip name (use bash -c for glob expansion)
    local remote_results_dir
    remote_results_dir=$($SSHV_COMMAND "$SSH_USER@$node" "sudo bash -c 'ls -td /root/TDAS/dcgmprof-* 2>/dev/null | head -1'" 2>/dev/null | tr -d '\r')
    
    # If it's a zip file, strip the .zip extension to get the base path
    if [[ "$remote_results_dir" == *.zip ]]; then
        remote_results_dir="${remote_results_dir%.zip}"
    fi
    
    if [[ -n "$remote_results_dir" ]]; then
        local results_basename=$(basename "$remote_results_dir")
        
        # Check if zip exists (remote script may have zipped and deleted the directory)
        local zip_exists dir_exists
        zip_exists=$($SSHV_COMMAND "$SSH_USER@$node" "sudo test -f '${remote_results_dir}.zip' && echo yes || echo no" 2>/dev/null | tr -d '\r')
        dir_exists=$($SSHV_COMMAND "$SSH_USER@$node" "sudo test -d '${remote_results_dir}' && echo yes || echo no" 2>/dev/null | tr -d '\r')
        
        echo -e "${YELLOW}[NODE: $node]${NC} Downloading TDAS results..."
        local download_success=false
        
        if [[ "$zip_exists" == "yes" ]]; then
            # Download the existing zip directly
            echo -e "${DIM}  Remote zip found, downloading...${NC}"
            local remote_zip="${remote_results_dir}.zip"
            local tmp_zip="/tmp/$(basename "$remote_zip")"
            
            # Copy to /tmp for permissions
            $SSHV_COMMAND "$SSH_USER@$node" "sudo cp '$remote_zip' '$tmp_zip' && sudo chmod 644 '$tmp_zip'" 2>/dev/null
            
            local download_error
            download_error=$($SSHV_COMMAND scp $SCP_OPTIONS "$SSH_USER@$node:$tmp_zip" "$node_dir/" 2>&1)
            
            if [[ $? -eq 0 ]]; then
                # Extract the zip contents into node_dir
                local downloaded_zip="$node_dir/$(basename "$remote_zip")"
                
                # Check downloaded zip size before extracting
                local dl_zip_size=$(du -h "$downloaded_zip" | cut -f1)
                echo -e "${DIM}  Downloaded zip: $dl_zip_size${NC}"
                
                # Extract and list what we got
                unzip -o "$downloaded_zip" -d "$node_dir/" >/dev/null 2>&1
                local unzip_status=$?
                rm -f "$downloaded_zip"
                
                if [[ $unzip_status -eq 0 ]]; then
                    download_success=true
                    local file_count=$(find "$node_dir" -type f | wc -l | tr -d ' ')
                    echo -e "${GREEN}  ✓ Extracted $file_count files from zip${NC}"
                else
                    echo -e "${RED}  ✗ Failed to extract zip (exit code: $unzip_status)${NC}"
                fi
            else
                echo -e "${RED}  ✗ Failed to download zip${NC}"
                echo -e "${DIM}    Error: $(echo "$download_error" | head -2 | tr '\n' ' ')${NC}"
            fi
            
            # Cleanup temp file
            $SSHV_COMMAND "$SSH_USER@$node" "rm -f '$tmp_zip'" 2>/dev/null
            
        elif [[ "$dir_exists" == "yes" ]]; then
            # Directory exists, create tar and download
            echo -e "${DIM}  Remote directory found, creating tar...${NC}"
            local remote_tar="/tmp/thermal_results_${timestamp}.tar.gz"
            $SSHV_COMMAND "$SSH_USER@$node" "sudo tar -czf '$remote_tar' -C '$remote_results_dir' ." 2>/dev/null
            $SSHV_COMMAND "$SSH_USER@$node" "sudo chmod 644 '$remote_tar'" 2>/dev/null
            
            local download_error
            download_error=$($SSHV_COMMAND scp $SCP_OPTIONS "$SSH_USER@$node:$remote_tar" "$node_dir/" 2>&1)
            
            if [[ $? -eq 0 ]]; then
                # Extract tar contents directly into node_dir
                tar -xzf "$node_dir/$(basename $remote_tar)" -C "$node_dir/" 2>/dev/null
                rm -f "$node_dir/$(basename $remote_tar)"
                download_success=true
                
                local file_count=$(find "$node_dir" -type f | wc -l | tr -d ' ')
                echo -e "${GREEN}  ✓ Downloaded $file_count files${NC}"
            else
                echo -e "${RED}  ✗ Failed to download results${NC}"
                echo -e "${DIM}    Error: $(echo "$download_error" | head -2 | tr '\n' ' ')${NC}"
            fi
            
            # Cleanup remote tar
            $SSHV_COMMAND "$SSH_USER@$node" "rm -f '$remote_tar'" 2>/dev/null
        else
            echo -e "${RED}  ✗ Neither zip nor directory found at ${remote_results_dir}${NC}"
        fi
        
        # Create individual node zip (Dell v2.6 format: zip contains dcgmprof-* folder with ~13 files)
        if [[ "$download_success" == "true" ]]; then
            # Find the dcgmprof-* folder that was downloaded
            local dcgm_folder=$(find "$node_dir" -maxdepth 1 -type d -name "dcgmprof-*" | head -1)
            
            if [[ -n "$dcgm_folder" && -d "$dcgm_folder" ]]; then
                local dcgm_folder_name=$(basename "$dcgm_folder")
                local file_count=$(find "$dcgm_folder" -type f | wc -l | tr -d ' ')
                
                # Remove only VP internal tracking files before zipping
                # Dell v2.6 keeps: thermal_results.*.csv, TSR_*.zip, dcgmproftester.log, tensor_active_*.results
                rm -f "${dcgm_folder}/test_completion_marker" 2>/dev/null
                rm -f "${dcgm_folder}/final_exit_code" 2>/dev/null
                rm -f "${dcgm_folder}/stopped_services.txt" 2>/dev/null
                rm -f "${dcgm_folder}/service_tag.txt" 2>/dev/null
                rm -f "${dcgm_folder}/gpu_metrics_raw.csv" 2>/dev/null
                # Keep: thermal_results.*.csv, TSR_*.zip, dcgmproftester.log, tensor_active_*.results
                
                # Recount files after cleanup
                file_count=$(find "$dcgm_folder" -type f | wc -l | tr -d ' ')
                echo -e "${YELLOW}[NODE: $node]${NC} Creating node zip (${file_count} files)..."
                
                # Create zip with dcgmprof folder at root (Dell v2.6 structure)
                # Structure: hostname-ServiceTag.zip > dcgmprof-XXXXX/ > ~13 files
                (cd "$node_dir" && zip -r "$node_zip_path" "$dcgm_folder_name" >/dev/null 2>&1)
                
                if [[ -f "$node_zip_path" ]]; then
                    local zip_size=$(du -h "$node_zip_path" | cut -f1)
                    echo -e "${GREEN}  ✓ Created: ${node_zip_name} (${zip_size})${NC}"
                    
                    # Cleanup temp folder
                    rm -rf "$node_dir"
                    
                    # Cleanup remote TDAS results
                    echo -e "${YELLOW}[NODE: $node]${NC} Cleaning up remote test files..."
                    $SSHV_COMMAND "$SSH_USER@$node" "sudo rm -rf '${remote_results_dir}' '${remote_results_dir}.zip' 2>/dev/null" 2>/dev/null
                    echo -e "${GREEN}  ✓ Remote cleanup complete${NC}"
                else
                    echo -e "${RED}  ✗ Failed to create node zip${NC}"
                fi
            else
                echo -e "${RED}  ✗ No dcgmprof-* folder found in downloaded results${NC}"
                ls -la "$node_dir" 2>/dev/null
            fi
        else
            echo -e "${RED}  ✗ Download failed - keeping remote files for manual retrieval${NC}"
        fi
    else
        echo -e "${RED}[NODE: $node]${NC} No results directory found in /root/TDAS"
    fi
    
    # Cleanup remote temp files (script, wrapper)
    $SSHV_COMMAND "$SSH_USER@$node" "rm -f /tmp/thermal_diag.sh $remote_wrapper" 2>/dev/null
    
    return $test_status
}

# Function to run thermal tests on multiple nodes
run_multinode_tests() {
    # Check for sshv first
    if ! check_sshv; then
        return 1
    fi
    
    local nodes=($NODE_LIST)
    local total_nodes=${#nodes[@]}
    local completed=0
    local failed=0
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Multi-Node Thermal Diagnostics${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Nodes to test: $total_nodes"
    echo -e "Parallel jobs: $PARALLEL_JOBS"
    echo -e "SSH Command: $SSHV_COMMAND"
    echo -e "SSH User: $SSH_USER"
    echo -e "Altitude: ${altitude_ft:-'Will prompt'}"
    echo -e "Reports directory: $REPORTS_DIR"
    echo -e "${BLUE}========================================${NC}"
    
    # Prompt for altitude if not set
    if [[ -z "${altitude_ft:-}" ]]; then
        echo ""
        echo "Select altitude for all nodes:"
        echo "  1) FTW1 (653 ft)"
        echo "  2) STR1 (289 ft)"
        echo "  3) PYL1 (220 ft)"
        echo "  4) ALN1 (656 ft)"
        echo "  5) Custom"
        read -p "Enter your choice [1-5]: " site_choice
        
        case $site_choice in
            1) altitude_ft=653 ;;
            2) altitude_ft=289 ;;
            3) altitude_ft=220 ;;
            4) altitude_ft=656 ;;
            5) read -p "Enter custom altitude in feet: " altitude_ft ;;
            *) echo "Invalid choice, using 0"; altitude_ft=0 ;;
        esac
        echo -e "${GREEN}Using altitude: ${altitude_ft} ft for all nodes${NC}"
    fi
    
    # Use DC name from CLI or prompt for it
    local dc_name="${DC_NAME:-}"
    if [[ -z "$dc_name" ]]; then
        echo ""
        echo -e "${CYAN}Enter datacenter/site name for this rollup:${NC}"
        echo -e "${DIM}(e.g., iad1-c2, ftw1-a1, str1-b3)${NC}"
        read -p "DC Name: " dc_name
        dc_name="${dc_name:-thermal-rollup}"  # Default if empty
    else
        echo -e "${GREEN}Using DC name from CLI: ${dc_name}${NC}"
    fi
    
    # Create timestamped parent folder for all node results
    local rollup_timestamp=$(date +"%Y%m%d-%H%M%S")
    local rollup_folder_name="${dc_name}-${rollup_timestamp}"
    local rollup_dir="${REPORTS_DIR}/${rollup_folder_name}"
    mkdir -p "$rollup_dir"
    
    echo -e "${GREEN}Results will be saved to: ${rollup_dir}${NC}"
    
    # Show pre-flight warning
    echo ""
    echo -e "${YELLOW}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}${BOLD}║                    ⚠️  IMPORTANT WARNING                    ║${NC}"
    echo -e "${YELLOW}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Before thermal tests can run, remote nodes must have:${NC}"
    echo -e "  ${CYAN}1.${NC} No running GPU processes (ollama, python ML, etc.)"
    echo -e "  ${CYAN}2.${NC} Container services stopped (kubelet, containerd, docker)"
    echo ""
    echo -e "${CYAN}Current settings:${NC}"
    if [[ "$AUTO_KILL_GPU_PROCESSES" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Auto-kill GPU processes: ${GREEN}enabled${NC}"
    else
        echo -e "  ${RED}✗${NC} Auto-kill GPU processes: ${RED}disabled${NC}"
    fi
    if [[ "$AUTO_STOP_SERVICES" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Auto-stop services: ${GREEN}enabled${NC}"
    else
        echo -e "  ${RED}✗${NC} Auto-stop services: ${RED}disabled${NC}"
    fi
    echo ""
    
    # Give user option to enable auto-handling
    if [[ "$AUTO_STOP_SERVICES" != "true" ]] || [[ "$AUTO_KILL_GPU_PROCESSES" != "true" ]]; then
        echo -e "${DIM}Tests will ABORT on nodes with running processes/services unless auto-handling is enabled.${NC}"
        echo ""
        read -p "Enable auto-handling for GPU processes AND services? (Y/n): " enable_auto
        if [[ "$enable_auto" =~ ^[Nn]$ ]]; then
            echo -e "${YELLOW}⚠ Auto-handling disabled. Tests will abort if processes/services are running.${NC}"
            read -p "Continue anyway? (y/N): " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Cancelled.${NC}"
                return 1
            fi
        else
            AUTO_STOP_SERVICES=true
            AUTO_KILL_GPU_PROCESSES=true
            echo -e "${GREEN}✓ Auto-handling enabled for GPU processes and services${NC}"
        fi
    else
        echo -e "${GREEN}✓ Auto-handling already enabled${NC}"
    fi
    
    # Create reports directory
    mkdir -p "$REPORTS_DIR"
    
    # Track background jobs
    local job_pids=()
    local job_nodes=()
    
    # Create status tracking directory
    local status_dir="/tmp/thermal_multinode_$$"
    mkdir -p "$status_dir"
    
    # Store start time
    local start_time=$(date +%s)
    
    # Calculate estimated completion time (test ~15min + download/zip ~10min)
    local test_duration=1500  # 25 minutes in seconds
    local est_complete_time=$(date -v+${test_duration}S "+%H:%M" 2>/dev/null || date -d "+${test_duration} seconds" "+%H:%M" 2>/dev/null || echo "~25 min")
    
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              THERMAL TESTS STARTING                        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Nodes:${NC}              $total_nodes"
    echo -e "  ${CYAN}Test duration:${NC}      ~25 minutes per node (test + download)"
    echo -e "  ${CYAN}Est. completion:${NC}    ${est_complete_time}"
    echo ""
    echo -e "${YELLOW}${BOLD}>>> Tests running in background - progress updates below <<<${NC}"
    echo ""
    
    # Start all jobs (output redirected to log files to keep progress display clean)
    for node in "${nodes[@]}"; do
        # Create status file and log file for this node
        echo "starting" > "$status_dir/${node}.status"
        echo "0" > "$status_dir/${node}.percent"
        local node_log="$status_dir/${node}.log"
        
        # Run test in background with status tracking (output to log file)
        local node_status_file="$status_dir/${node}.status"
        (
            echo "running" > "$node_status_file"
            if run_on_remote_node "$node" "$altitude_ft" "$rollup_dir" "$node_status_file"; then
                echo "completed" > "$node_status_file"
            else
                echo "failed" > "$node_status_file"
            fi
        ) >> "$node_log" 2>&1 &
        
        job_pids+=($!)
        job_nodes+=("$node")
        
        # Stagger starts slightly to avoid SSH connection storms
        sleep 2
    done
    
    # Calculate display height (header + nodes + footer)
    local display_lines=$((10 + total_nodes))
    
    # Function to get last activity line from node log
    get_node_activity() {
        local node="$1"
        local log_file="$status_dir/${node}.log"
        if [[ -f "$log_file" ]]; then
            # Get last meaningful line: strip colors, shell trace prefixes (+ ++ +++), and truncate
            # Look for lines containing useful keywords
            local activity=""
            activity=$(tail -20 "$log_file" 2>/dev/null | \
                sed 's/\x1b\[[0-9;]*m//g' | \
                sed 's/^[+ ]*//g' | \
                grep -iE 'upload|download|running|test|dcgm|nvidia|complete|start|stop|service|install|check' | \
                tail -1 | \
                cut -c1-28)
            
            # Fallback: just get last non-trace line
            if [[ -z "$activity" ]]; then
                activity=$(tail -5 "$log_file" 2>/dev/null | \
                    sed 's/\x1b\[[0-9;]*m//g' | \
                    sed 's/^[+ ]*//g' | \
                    grep -v '^\[' | \
                    grep -v '^$' | \
                    tail -1 | \
                    cut -c1-28)
            fi
            
            echo "$activity"
        fi
    }
    
    # Function to draw the progress display (clears and redraws)
    draw_progress() {
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        
        # First pass: count completed/failed nodes for accurate progress
        local running=0 done_count=0 fail=0 downloading=0
        for node in "${nodes[@]}"; do
            local status="unknown"
            [[ -f "$status_dir/${node}.status" ]] && status=$(cat "$status_dir/${node}.status")
            case "$status" in
                completed) done_count=$((done_count + 1)) ;;
                failed) fail=$((fail + 1)) ;;
                downloading) downloading=$((downloading + 1)) ;;
                running|starting) running=$((running + 1)) ;;
            esac
        done
        
        # Calculate progress based on node completion, not just time
        local finished=$((done_count + fail))
        local in_progress=$((running + downloading))
        local percent=0
        if [[ $total_nodes -gt 0 ]]; then
            percent=$((finished * 100 / total_nodes))
        fi
        # If still running or downloading, cap at 99% until truly complete
        if [[ $in_progress -gt 0 && $percent -ge 100 ]]; then
            percent=99
        fi
        
        # Estimate remaining time based on how long completed nodes took
        local remaining=0
        if [[ $in_progress -gt 0 ]]; then
            if [[ $finished -gt 0 ]]; then
                # Estimate based on average time per completed node
                local avg_time=$((elapsed / finished))
                remaining=$((avg_time * in_progress))
            else
                # No nodes done yet, use initial estimate minus elapsed
                remaining=$((test_duration - elapsed))
                [[ $remaining -lt 0 ]] && remaining=60  # At least show 1 min if over estimate
            fi
            # Downloading nodes are almost done, reduce remaining estimate
            if [[ $downloading -gt 0 && $running -eq 0 ]]; then
                remaining=$((remaining / 3))  # Download phase is ~1/3 of total time
            fi
        fi
        local rem_mins=$((remaining / 60))
        
        # Build overall progress bar
        local bar_width=40
        local filled=$((percent * bar_width / 100))
        local empty=$((bar_width - filled))
        local bar=$(printf "%${filled}s" | tr ' ' '█')$(printf "%${empty}s" | tr ' ' '░')
        
        # Clear screen and move to top
        clear
        
        # Draw header
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}  ${BOLD}THERMAL TEST PROGRESS${NC}                                                    ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
        printf "${BLUE}║${NC}  Elapsed: ${CYAN}%3dm %02ds${NC}  │  Remaining: ${YELLOW}~%2dm${NC}  │  Overall: ${GREEN}%3d%%${NC}                 ${BLUE}║${NC}\n" "$mins" "$secs" "$rem_mins" "$percent"
        echo -e "${BLUE}║${NC}  [${GREEN}${bar}${NC}]        ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
        
        # Reset counters for display (already counted above)
        running=0; done_count=0; fail=0; downloading=0
        
        for node in "${nodes[@]}"; do
            local status="unknown"
            [[ -f "$status_dir/${node}.status" ]] && status=$(cat "$status_dir/${node}.status")
            
            # Calculate per-node progress bar based on time
            local node_start_file="$status_dir/${node}.start"
            local node_elapsed=0
            local node_percent=0
            
            if [[ -f "$node_start_file" ]]; then
                local node_start=$(cat "$node_start_file")
                node_elapsed=$(($(date +%s) - node_start))
                node_percent=$((node_elapsed * 100 / test_duration))
                # Cap at 99% while still running
                if [[ "$status" == "running" && $node_percent -ge 100 ]]; then
                    node_percent=99
                elif [[ $node_percent -gt 100 ]]; then
                    node_percent=100
                fi
            fi
            
            local node_bar_width=15
            local node_filled=$((node_percent * node_bar_width / 100))
            local node_empty=$((node_bar_width - node_filled))
            local node_bar=$(printf "%${node_filled}s" | tr ' ' '▓')$(printf "%${node_empty}s" | tr ' ' '░')
            
            local status_icon status_color activity=""
            case "$status" in
                starting)
                    status_icon="⏳"; status_color="${YELLOW}"
                    node_bar=$(printf "%${node_bar_width}s" | tr ' ' '·')
                    activity="Initializing..."
                    ;;
                running)
                    status_icon="●"; status_color="${CYAN}"
                    activity=$(get_node_activity "$node")
                    running=$((running + 1))
                    ;;
                downloading)
                    status_icon="↓"; status_color="${MAGENTA}"
                    node_bar=$(printf "%${node_bar_width}s" | tr ' ' '▓')
                    node_percent=95
                    activity="Downloading results..."
                    downloading=$((downloading + 1))
                    ;;
                completed)
                    status_icon="✓"; status_color="${GREEN}"
                    node_bar=$(printf "%${node_bar_width}s" | tr ' ' '█')
                    node_percent=100
                    activity="Done"
                    done_count=$((done_count + 1))
                    ;;
                failed)
                    status_icon="✗"; status_color="${RED}"
                    activity="Failed"
                    fail=$((fail + 1))
                    ;;
                *)
                    status_icon="?"; status_color="${DIM}"
                    ;;
            esac
            
            # Truncate activity to fit display
            activity="${activity:0:30}"
            printf "${BLUE}║${NC}  ${status_color}${status_icon}${NC} %-16s [${status_color}%-15s${NC}] %3d%% ${DIM}%-30s${NC} ${BLUE}║${NC}\n" "$node" "$node_bar" "$node_percent" "$activity"
        done
        
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
        printf "${BLUE}║${NC}  Running: ${CYAN}%d${NC}  │  Downloading: ${MAGENTA}%d${NC}  │  Done: ${GREEN}%d${NC}  │  Failed: ${RED}%d${NC}  │  Total: %d   ${BLUE}║${NC}\n" "$running" "$downloading" "$done_count" "$fail" "$total_nodes"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${DIM}Press Ctrl+C to abort (tests will continue on remote nodes)${NC}"
    }
    
    # Record start time for each node when it starts running
    for node in "${nodes[@]}"; do
        echo "$(date +%s)" > "$status_dir/${node}.start"
    done
    
    # Initial progress display after brief delay for jobs to start
    sleep 3
    draw_progress
    
    # Wait for all jobs with real-time progress updates
    while true; do
        # Check if any jobs still running
        local still_running=0
        for pid in "${job_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                still_running=$((still_running + 1))
            fi
        done
        
        if [[ $still_running -eq 0 ]]; then
            break
        fi
        
        # Update progress every 5 seconds
        sleep 5
        draw_progress
    done
    
    # Final update
    draw_progress
    
    # Final status check and collect failed nodes
    local failed_nodes=()
    for node in "${nodes[@]}"; do
        local status=$(cat "$status_dir/${node}.status" 2>/dev/null || echo "unknown")
        if [[ "$status" == "completed" ]]; then
            completed=$((completed + 1))
        else
            failed=$((failed + 1))
            failed_nodes+=("$node")
        fi
    done
    
    # Move past the progress display for summary
    echo ""
    echo ""
    
    # Summary
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Multi-Node Test Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  Total nodes:    $total_nodes"
    echo -e "  Completed:      ${GREEN}$completed${NC}"
    echo -e "  Failed:         ${RED}$failed${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    
    # Show logs for failed nodes
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        echo -e "\n${RED}Failed node logs:${NC}"
        for node in "${failed_nodes[@]}"; do
            local log_file="$status_dir/${node}.log"
            if [[ -f "$log_file" ]]; then
                echo -e "\n${YELLOW}=== $node ===${NC}"
                tail -20 "$log_file" | sed 's/\x1b\[[0-9;]*m//g'
            fi
        done
    fi
    
    # List individual node zip files
    echo -e "\n${GREEN}Individual node zips (Dell format):${NC}"
    ls -lh "$rollup_dir"/*.zip 2>/dev/null || echo "No node zips generated"
    
    # Create final rollup zip containing all individual node zips
    # Structure: rollup.zip > g329-7871FZ3.zip, g330-DV42FZ3.zip, ...
    local rollup_zip="${REPORTS_DIR}/${rollup_folder_name}.zip"
    echo -e "\n${YELLOW}Creating rollup zip (zip of zips)...${NC}"
    (cd "$rollup_dir" && zip -r "$rollup_zip" *.zip >/dev/null 2>&1)
    
    if [[ -f "$rollup_zip" ]]; then
        local zip_size=$(du -h "$rollup_zip" | cut -f1)
        local zip_count=$(ls -1 "$rollup_dir"/*.zip 2>/dev/null | wc -l | tr -d ' ')
        echo -e "${GREEN}✓ Created: ${rollup_zip}${NC}"
        echo -e "${GREEN}  Size: ${zip_size} (${zip_count} node zips inside)${NC}"
        echo ""
        echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  Submit to Dell: ${rollup_zip}${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}✗ Failed to create rollup zip${NC}"
        echo -e "${DIM}Individual node zips available at: ${rollup_dir}${NC}"
    fi
    
    # Cleanup status files (after showing logs)
    rm -rf "$status_dir"
    
    return $failed
}

# Parse command line arguments for multi-node mode
parse_multinode_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nodes)
                MULTI_NODE_MODE=true
                NODE_LIST="$2"
                shift 2
                ;;
            --nodes-file)
                MULTI_NODE_MODE=true
                if [[ -f "$2" ]]; then
                    NODE_LIST=$(cat "$2" | grep -v '^#' | grep -v '^$' | tr '\n' ' ')
                else
                    echo "Error: Nodes file not found: $2"
                    exit 1
                fi
                shift 2
                ;;
            --user)
                SSH_USER="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --altitude)
                altitude_ft="$2"
                shift 2
                ;;
            --reports-dir)
                REPORTS_DIR="$2"
                shift 2
                ;;
            --dc-name|--dc)
                DC_NAME="$2"
                shift 2
                ;;
            --auto-stop-services)
                AUTO_STOP_SERVICES=true
                shift
                ;;
            --auto-kill-gpu)
                AUTO_KILL_GPU_PROCESSES=true
                shift
                ;;
            --auto-all)
                AUTO_STOP_SERVICES=true
                AUTO_KILL_GPU_PROCESSES=true
                shift
                ;;
            --help|-h)
                show_multinode_help
                exit 0
                ;;
            --version|-V)
                echo "GPU Thermal Diagnostics Tool - Version ${SCRIPT_VERSION:-2.6.2-vp} (${SCRIPT_TAG:-latest})"
                echo "Based on Dell dcgmprofrunner.sh v2.6"
                exit 0
                ;;
            --multi)
                # Interactive mode - will prompt for nodes
                MULTI_NODE_MODE=true
                shift
                ;;
            *)
                # Unknown argument, might be for local mode
                shift
                ;;
        esac
    done
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

# Colors for output (need to define here for multi-node mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Script version
SCRIPT_VERSION="2.6.2-vp"
SCRIPT_TAG="latest"

# Function to display main menu
show_main_menu() {
    clear
    echo ""
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║          GPU Thermal Diagnostics Tool (TDWDL)              ║${NC}"
    echo -e "${BLUE}${BOLD}║                Version ${SCRIPT_VERSION} (${SCRIPT_TAG})                  ║${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}Select Mode:${NC}"
    echo -e "  ${GREEN}1)${NC} Run on THIS machine ${DIM}(local execution)${NC}"
    echo -e "  ${GREEN}2)${NC} Run on MULTIPLE nodes ${DIM}(remote execution via sshv)${NC}"
    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}h)${NC} Help / CLI Usage"
    echo -e "  ${YELLOW}v)${NC} Version info"
    echo -e "  ${RED}0)${NC} Exit"
    echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${DIM}NOTE: Results must be submitted to Dell for thermal analysis${NC}"
    echo -e "${DIM}      and RMA determination. This tool collects data only.${NC}"
}

# Function to show version info
show_version_info() {
    echo ""
    echo -e "${CYAN}${BOLD}GPU Thermal Diagnostics Tool${NC}"
    echo -e "Version: ${GREEN}${SCRIPT_VERSION}${NC} (${CYAN}${SCRIPT_TAG}${NC})"
    echo -e "Based on: Dell dcgmprofrunner.sh v2.6"
    echo ""
    echo -e "${YELLOW}Changes from Dell v2.6:${NC}"
    echo -e "  • Multi-node execution support via sshv"
    echo -e "  • Automatic result download and cleanup"
    echo -e "  • Non-interactive mode for automation"
    echo -e "  • Failure detection removed (per Dell v2.6 alignment)"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo -e "  Results must be submitted to Dell for thermal analysis"
    echo -e "  and RMA determination. Dell uses internal tools to"
    echo -e "  interpret the collected data."
    echo ""
}

# Function to show multi-node submenu
show_multinode_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║     Multi-Node Execution Options       ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Enter node IPs/hostnames manually"
    echo -e "  ${GREEN}2)${NC} Load nodes from file"
    echo ""
    echo -e "${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}b)${NC} Back to main menu"
    echo -e "${DIM}────────────────────────────────────────${NC}"
}

# Function to get nodes from file
get_nodes_from_file() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local nodes_file=""
    
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Load Nodes from File             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    
    # Look for existing node list files in script directory
    local found_files=()
    while IFS= read -r -d '' file; do
        # Check if file contains IP-like patterns
        if grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$file" 2>/dev/null || \
           grep -qE '^[a-zA-Z0-9]+-?[a-zA-Z0-9]+' "$file" 2>/dev/null; then
            found_files+=("$file")
        fi
    done < <(find "$script_dir" -maxdepth 1 -type f \( -name "*.txt" -o -name "*.list" -o -name "nodes*" -o -name "*nodes*" \) -print0 2>/dev/null)
    
    echo ""
    echo -e "  ${BOLD}1)${NC} Enter file path manually"
    echo -e "  ${BOLD}2)${NC} Create new file (opens editor)"
    
    if [[ ${#found_files[@]} -gt 0 ]]; then
        echo -e "\n  ${DIM}── Found in script folder ──${NC}"
        local opt=3
        for file in "${found_files[@]}"; do
            local basename=$(basename "$file")
            local line_count=$(grep -cE '^[0-9]+\.[0-9]+|^[a-zA-Z0-9]' "$file" 2>/dev/null || echo 0)
            echo -e "  ${BOLD}${opt})${NC} ${basename} ${DIM}(~${line_count} nodes)${NC}"
            opt=$((opt + 1))
        done
    fi
    
    echo ""
    read -p "Select option: " file_choice
    
    case "$file_choice" in
        1)
            # Manual path entry
            echo -e "\n${DIM}(One node per line, lines starting with # are ignored)${NC}"
            read -p "File path: " nodes_file
            ;;
        2)
            # Create new file with editor
            local new_file="$script_dir/nodes_$(date +%Y%m%d_%H%M%S).txt"
            echo -e "\n${YELLOW}Creating new node list file...${NC}"
            echo -e "${DIM}Enter one IP or hostname per line. Save and exit when done.${NC}"
            echo ""
            
            # Detect available editor
            local editor=""
            if [[ -n "$EDITOR" ]]; then
                editor="$EDITOR"
            elif command -v nano &>/dev/null; then
                editor="nano"
            elif command -v vim &>/dev/null; then
                editor="vim"
            elif command -v vi &>/dev/null; then
                editor="vi"
            else
                # Fallback: simple read loop
                echo -e "${YELLOW}No editor found. Enter IPs manually (one per line, empty line to finish):${NC}"
                local temp_content=""
                while true; do
                    read -p "> " line
                    [[ -z "$line" ]] && break
                    temp_content+="$line"$'\n'
                done
                echo "$temp_content" > "$new_file"
                nodes_file="$new_file"
                echo -e "${GREEN}Saved to: $new_file${NC}"
                break
            fi
            
            # Create template file
            cat > "$new_file" << 'TEMPLATE'
# Node list for thermal diagnostics
# One IP or hostname per line
# Lines starting with # are ignored

TEMPLATE
            
            # Open editor
            $editor "$new_file"
            nodes_file="$new_file"
            echo -e "${GREEN}Saved to: $new_file${NC}"
            ;;
        *)
            # Check if it's a found file selection
            local idx=$((file_choice - 3))
            if [[ $idx -ge 0 && $idx -lt ${#found_files[@]} ]]; then
                nodes_file="${found_files[$idx]}"
                echo -e "\n${GREEN}Selected: $(basename "$nodes_file")${NC}"
            else
                echo -e "${RED}Invalid option${NC}"
                return 1
            fi
            ;;
    esac

    if [[ ! -f "$nodes_file" ]]; then
        echo -e "${RED}File not found: $nodes_file${NC}"
        return 1
    fi

    NODE_LIST=$(cat "$nodes_file" | grep -v '^#' | grep -v '^$' | tr '\n' ' ')

    if [[ -z "$NODE_LIST" ]]; then
        echo -e "${RED}No valid nodes found in file${NC}"
        return 1
    fi

    local node_count=$(echo "$NODE_LIST" | wc -w | tr -d ' ')
    echo -e "\n${GREEN}Loaded ${node_count} node(s):${NC}"

    local i=1
    for node in $NODE_LIST; do
        echo -e "  ${CYAN}$i)${NC} $node"
        i=$((i + 1))
    done

    echo ""
    read -p "Proceed with these nodes? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    
    return 0
}

# Function to get manual IP input (like start-node-toolkit.sh)
get_manual_node_input() {
    echo -e "\n${YELLOW}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}${BOLD}║       Enter Target Nodes               ║${NC}"
    echo -e "${YELLOW}${BOLD}╚════════════════════════════════════════╝${NC}"
    
    echo -e "\n${CYAN}${BOLD}Enter Node IPs or Hostnames:${NC}"
    echo -e "${DIM}Accepts: space, comma, or newline separated${NC}"
    echo -e "${DIM}Press Enter twice or Ctrl+D when finished${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    local all_input=""
    local line=""
    local empty_count=0
    
    while true; do
        read -r line
        if [[ -z "$line" ]]; then
            ((empty_count++))
            if [[ $empty_count -ge 1 ]]; then
                break
            fi
        else
            empty_count=0
            all_input+=" $line"
        fi
    done
    
    # Normalize input (replace commas and newlines with spaces)
    NODE_LIST=$(echo "$all_input" | tr ',[:space:]' ' ' | xargs)
    
    if [[ -z "$NODE_LIST" ]]; then
        echo -e "${RED}No nodes specified.${NC}"
        return 1
    fi
    
    # Count and display nodes
    local node_count=$(echo "$NODE_LIST" | wc -w | tr -d ' ')
    echo -e "\n${GREEN}Found ${node_count} node(s):${NC}"
    
    local i=1
    for node in $NODE_LIST; do
        echo -e "  ${CYAN}$i)${NC} $node"
        ((i++))
    done
    
    echo ""
    read -p "Proceed with these nodes? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    fi
    
    return 0
}

# Function to get SSH user
get_ssh_user() {
    echo -e "\n${CYAN}SSH User Configuration${NC}"
    echo -e "Current user: ${GREEN}$SSH_USER${NC}"
    read -p "Enter SSH user (press Enter for '$SSH_USER'): " new_user
    if [[ -n "$new_user" ]]; then
        SSH_USER="$new_user"
    fi
    echo -e "Using SSH user: ${GREEN}$SSH_USER${NC}"
}

# Function to run main menu
run_main_menu() {
    while true; do
        show_main_menu
        echo -ne "${CYAN}Select option: ${NC}"
        read -r choice
        
        case "$choice" in
            1)
                # Local mode - check if we're on a GPU server
                if [[ "$(uname)" == "Darwin" ]]; then
                    echo -e "\n${RED}Cannot run local mode on macOS.${NC}"
                    echo -e "${YELLOW}This tool requires a Linux server with NVIDIA GPUs.${NC}"
                    echo -e "${YELLOW}Use option 2 to run on remote nodes.${NC}"
                    continue
                fi
                
                # Check for root and run main()
                if [ "$EUID" -ne 0 ]; then
                    echo "This script requires root privileges. Re-running with sudo..."
                    exec sudo bash "$0" --local "$@"
                fi
                
                display_message "INFO" "Starting thermal diagnostics script (TDWDL Version)"
                main
                display_message "INFO" "Exiting thermal diagnostics script (TDWDL Version)"
                exit $?
                ;;
            2)
                # Multi-node mode submenu
                while true; do
                    show_multinode_menu
                    echo -ne "${CYAN}Select option: ${NC}"
                    read -r mn_choice
                    
                    case "$mn_choice" in
                        1)
                            MULTI_NODE_MODE=true
                            get_ssh_user
                            if get_manual_node_input; then
                                run_multinode_tests
                                exit $?
                            fi
                            ;;
                        2)
                            MULTI_NODE_MODE=true
                            get_ssh_user
                            if get_nodes_from_file; then
                                run_multinode_tests
                                exit $?
                            fi
                            ;;
                        b|B)
                            break
                            ;;
                        *)
                            echo -e "${RED}Invalid option.${NC}"
                            ;;
                    esac
                done
                ;;
            h|H)
                show_multinode_help
                echo ""
                read -p "Press Enter to continue..."
                ;;
            v|V)
                show_version_info
                read -p "Press Enter to continue..."
                ;;
            0|q|Q)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                ;;
        esac
    done
}

# Parse arguments first (before root check for multi-node mode)
parse_multinode_args "$@"

# Check if running with specific flags
if [[ "$MULTI_NODE_MODE" == "true" ]]; then
    # Multi-node mode from CLI args
    if [[ -z "$NODE_LIST" ]]; then
        # Interactive node input
        get_manual_node_input || exit 1
    fi
    
    run_multinode_tests
    exit $?
elif [[ "${1:-}" == "--local" ]]; then
    # Direct local execution (called from menu after sudo)
    shift
    display_message "INFO" "Starting thermal diagnostics script (TDWDL Version)"
    main
    display_message "INFO" "Exiting thermal diagnostics script (TDWDL Version)"
    exit $?
elif [[ $# -eq 0 ]]; then
    # No arguments - show menu
    run_main_menu
else
    # Unknown arguments - show help
    show_multinode_help
    exit 1
fi