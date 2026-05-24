#!/bin/bash

# Script Name
SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOG_FILE="$BASE_DIR/Logs/$SCRIPT_NAME.log"
CONFIG_FILE="$BASE_DIR/Variables/$SCRIPT_NAME.json"
GLOBAL_FILE="$BASE_DIR/Variables/_Global.json"

ENVIRONMENT="#{ENVIRONMENT}#"

# Logging function
write_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    echo "[$timestamp] [$level] [$ENVIRONMENT] $message" >> "$LOG_FILE"
    
    # Console output
    if [[ "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        echo -e "\e[31m[$level] $message\e[0m"
    elif [[ "$level" == "WARNING" ]]; then
        echo -e "\e[33m[$level] $message\e[0m"
    else
        echo "[$level] $message"
    fi
}

# Trap errors
trap 'write_log "Script encountered a terminating error on line $LINENO" "CRITICAL"; post_flight' ERR

post_flight() {
    if [ -f "$LOG_FILE" ]; then
        write_log "Scanning $LOG_FILE for errors in the last 5 minutes..." "INFO"
        
        python3 -c '
import sys
import datetime
import json
import smtplib
from email.mime.text import MIMEText

log_file = sys.argv[1]
config_json_str = sys.argv[2]
script_name = sys.argv[3]

try:
    config = json.loads(config_json_str)
except Exception:
    config = {}

email_to = config.get("EmailTo")
email_from = config.get("EmailFrom")
app_password = config.get("EmailAppPassword")

if not all([email_to, email_from, app_password]):
    print("WARNING: Email alerting is not configured in _Global.json.")
    sys.exit(0)

threshold = datetime.datetime.now() - datetime.timedelta(minutes=5)
errors = []

try:
    with open(log_file, "r") as f:
        for line in f:
            if "[ERROR]" in line or "[CRITICAL]" in line:
                parts = line.split("] ")
                if len(parts) > 0:
                    date_str = parts[0][1:]
                    try:
                        log_date = datetime.datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
                        if log_date >= threshold:
                            errors.append(line)
                    except:
                        pass
except Exception as e:
    print(f"WARNING: Failed to read log: {e}")
    sys.exit(0)

if errors:
    print(f"INFO: Found {len(errors)} errors. Sending email...")
    body = f"The following errors/alerts were detected in the {script_name} run:\n\n" + "".join(errors)
    msg = MIMEText(body)
    msg["Subject"] = f"Script Alert: {script_name} Errors Detected"
    msg["From"] = email_from
    msg["To"] = email_to
    
    try:
        server = smtplib.SMTP("smtp.gmail.com", 587)
        server.starttls()
        server.login(email_from, app_password)
        server.send_message(msg)
        server.quit()
        print("INFO: Email sent successfully.")
    except Exception as e:
        print(f"CRITICAL: Failed to send email: {e}")
' "$LOG_FILE" "$CONFIG_JSON" "$SCRIPT_NAME"
        
    else
        write_log "Log file not found at $LOG_FILE. Cannot scan for errors." "WARNING"
    fi
}

write_log "Initializing script execution." "INFO"

# Load Config using the Hiera helper
CONFIG_JSON=$(python3 "$BASE_DIR/Functions/get_script_config.py" "$SCRIPT_NAME")
if [ $? -ne 0 ] || [ -z "$CONFIG_JSON" ]; then
    write_log "FATAL: Failed to resolve configuration via get_script_config.py." "CRITICAL"
    exit 1
fi

INTERFACE_ALIAS=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('InterfaceAlias', ''))" "$CONFIG_JSON")
DNS_SUFFIX=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('DnsSuffix', ''))" "$CONFIG_JSON")

write_log "Loaded Configuration Variables:" "INFO"
write_log "  InterfaceAlias = $INTERFACE_ALIAS" "INFO"
write_log "  DnsSuffix = $DNS_SUFFIX" "INFO"

if [ -z "$DNS_SUFFIX" ]; then
    write_log "FATAL: DnsSuffix not specified in config." "CRITICAL"
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to configure network settings." "CRITICAL"
    exit 1
fi

# Resolve Interface
TARGET_INTERFACE="$INTERFACE_ALIAS"

if ! ip link show "$TARGET_INTERFACE" &>/dev/null; then
    write_log "Configured interface '$TARGET_INTERFACE' not found. Attempting to find default interface..." "WARNING"
    
    DEFAULT_IFACE=$(python3 -c '
import json
import subprocess
import sys

try:
    output = subprocess.check_output(["ip", "-j", "route"]).decode()
    routes = json.loads(output)
    for route in routes:
        if route.get("dst") == "default":
            print(route.get("dev"))
            sys.exit(0)
except Exception as e:
    pass
sys.exit(1)
')
    
    if [ $? -eq 0 ] && [ -n "$DEFAULT_IFACE" ]; then
        write_log "Found default interface: $DEFAULT_IFACE" "INFO"
        TARGET_INTERFACE="$DEFAULT_IFACE"
    else
        write_log "Failed to detect default interface. Aborting." "CRITICAL"
        exit 1
    fi
fi

# Apply DNS Suffix
if command -v resolvectl &> /dev/null; then
    write_log "resolvectl detected. Setting DNS search domain for $TARGET_INTERFACE." "INFO"
    
    # Check current setting
    CURRENT_DOMAINS=$(resolvectl status "$TARGET_INTERFACE" | grep "DNS Domain:" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
    
    if [[ "$CURRENT_DOMAINS" == *"$DNS_SUFFIX"* ]]; then
        write_log "DNS suffix '$DNS_SUFFIX' is already set on $TARGET_INTERFACE. No action taken." "INFO"
    else
        write_log "Setting DNS suffix '$DNS_SUFFIX' on $TARGET_INTERFACE." "INFO"
        resolvectl domain "$TARGET_INTERFACE" "$DNS_SUFFIX"
        
        if [ $? -eq 0 ]; then
            write_log "DNS suffix updated successfully." "INFO"
        else
            write_log "Failed to update DNS suffix via resolvectl." "ERROR"
        fi
    fi
else
    write_log "resolvectl not found. Traditional Linux network configuration detected." "WARNING"
    write_log "Please ensure search domain is set in /etc/resolv.conf or netplan manually." "INFO"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
