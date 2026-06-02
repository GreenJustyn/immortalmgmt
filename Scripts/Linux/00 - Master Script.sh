#!/bin/bash

# Script Name
SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOG_FILE="$BASE_DIR/Logs/$SCRIPT_NAME.log"
ENVIRONMENT="#{ENVIRONMENT}#"

# Logging helper
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    echo "[$timestamp] [$level] [$ENVIRONMENT] $message" >> "$LOG_FILE"
    
    if [[ "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        echo -e "\e[31m[$level] $message\e[0m"
    elif [[ "$level" == "WARNING" ]]; then
        echo -e "\e[33m[$level] $message\e[0m"
    else
        echo "[$level] $message"
    fi
}

write_log "Initializing Meta Master runner." "INFO"

CUSTOM_DIR="$SCRIPT_DIR/Custom"
if [ ! -d "$CUSTOM_DIR" ]; then
    write_log "Custom subdirectory not found at $CUSTOM_DIR. Creating..." "WARNING"
    mkdir -p "$CUSTOM_DIR"
fi

# Scan and sort all executable script files in Custom directory
CUSTOM_SCRIPTS=$(find "$CUSTOM_DIR" -maxdepth 1 -name "*.sh" | sort)

if [ -z "$CUSTOM_SCRIPTS" ]; then
    write_log "No custom actions found inside $CUSTOM_DIR. Master execution complete." "INFO"
    exit 0
fi

failed_count=0
for script in $CUSTOM_SCRIPTS; do
    script_name=$(basename "$script")
    write_log "--------------------------------------------------" "INFO"
    write_log "Executing Custom Script: $script_name..." "INFO"
    
    # Ensure it is executable
    chmod +x "$script"
    
    # Run script
    "$script"
    rc=$?
    
    if [ $rc -ne 0 ]; then
        write_log "Custom Script '$script_name' returned non-zero exit code: $rc" "ERROR"
        failed_count=$((failed_count + 1))
    else
        write_log "Custom Script '$script_name' executed successfully." "INFO"
    fi
done

write_log "--------------------------------------------------" "INFO"
if [ $failed_count -gt 0 ]; then
    write_log "Meta Master finished with $failed_count failed script(s)." "ERROR"
    exit 1
else
    write_log "All custom scripts executed successfully." "INFO"
    write_log "Meta Master execution completed." "INFO"
fi
