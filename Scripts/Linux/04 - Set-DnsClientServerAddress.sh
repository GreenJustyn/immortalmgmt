#!/bin/bash

# Script Name
SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOG_FILE="$BASE_DIR/Logs/$SCRIPT_NAME.log"
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

# Load Config using the Hiera helper
CONFIG_JSON=$(python3 "$BASE_DIR/Functions/get_script_config.py" "$SCRIPT_NAME")
if [ $? -ne 0 ] || [ -z "$CONFIG_JSON" ]; then
    write_log "FATAL: Failed to resolve configuration via get_script_config.py." "CRITICAL"
    exit 1
fi

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

# Load Config
CONFIG_FILE_CORRECT="$BASE_DIR/Variables/$SCRIPT_NAME.json"
CONFIG_FILE_TYPO="$BASE_DIR/Variables/04 - Set-DnsClientServerAddress.json"

if [ -f "$CONFIG_FILE_CORRECT" ]; then
    CONFIG_FILE="$CONFIG_FILE_CORRECT"
elif [ -f "$CONFIG_FILE_TYPO" ]; then
    CONFIG_FILE="$CONFIG_FILE_TYPO"
    write_log "Using config file with typo name: $CONFIG_FILE" "WARNING"
else
    write_log "FATAL: Config file missing at $CONFIG_FILE_CORRECT." "CRITICAL"
    exit 1
fi

CONFIG_JSON=$(python3 -c '
import json
import sys
try:
    with open(sys.argv[1], "r") as f:
        config = json.load(f)
    print(json.dumps(config))
except Exception as e:
    print("{}")
' "$CONFIG_FILE")

INTERFACE_ALIAS=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('InterfaceAlias', ''))" "$CONFIG_JSON")
DNS_SERVERS=$(python3 -c "import json, sys; print(' '.join(json.loads(sys.argv[1]).get('DnsServers', [])))" "$CONFIG_JSON")

if [ -z "$INTERFACE_ALIAS" ] || [ -z "$DNS_SERVERS" ]; then
    write_log "FATAL: Required config missing (InterfaceAlias or DnsServers)." "CRITICAL"
    exit 1
fi

write_log "Loaded Configuration Variables:" "INFO"
write_log "  InterfaceAlias = $INTERFACE_ALIAS" "INFO"
write_log "  DnsServers = $DNS_SERVERS" "INFO"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to change DNS settings." "CRITICAL"
    exit 1
fi

# Interface Check
if ! ip link show dev "$INTERFACE_ALIAS" &> /dev/null; then
    write_log "Interface $INTERFACE_ALIAS not found." "ERROR"
    exit 1
fi

# Idempotent Logic
CURRENT_DNS=""
if command -v nmcli &> /dev/null; then
    CURRENT_DNS=$(nmcli -g IP4.DNS connection show "$INTERFACE_ALIAS" 2>/dev/null | tr '\n' ' ')
fi

DIFF=$(python3 -c '
import sys
current = sys.argv[1].split()
desired = sys.argv[2].split()
if set(current) != set(desired):
    print("true")
else:
    print("")
' "$CURRENT_DNS" "$DNS_SERVERS")

if [ -n "$DIFF" ]; then
    write_log "DNS configuration drift detected. Enforcing: $DNS_SERVERS" "INFO"
    
    # Try nmcli first for persistence
    if command -v nmcli &> /dev/null; then
        write_log "Using nmcli to set DNS." "INFO"
        CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$INTERFACE_ALIAS$" | cut -d: -f1)
        if [ -z "$CON_NAME" ]; then
            CON_NAME="$INTERFACE_ALIAS"
        fi
        
        nmcli con mod "$CON_NAME" ipv4.dns "$DNS_SERVERS"
        nmcli con up "$CON_NAME"
        write_log "DNS Servers updated successfully." "INFO"
    else
        write_log "nmcli not found. Cannot reliably set persistent DNS without distro-specific logic." "ERROR"
        exit 1
    fi
else
    write_log "DNS Servers are already correct. No action taken." "INFO"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
