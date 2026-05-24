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

ENABLE_SMB1=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('EnableSMB1Protocol', False))" "$CONFIG_JSON")
REQUIRE_SIG=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('RequireSecuritySignature', True))" "$CONFIG_JSON")

write_log "Loaded Configuration Variables:" "INFO"
write_log "  EnableSMB1Protocol = $ENABLE_SMB1" "INFO"
write_log "  RequireSecuritySignature = $REQUIRE_SIG" "INFO"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    write_log "This script must be run as root to configure Samba." "CRITICAL"
    exit 1
fi

SMB_CONF="/etc/samba/smb.conf"

if [ ! -f "$SMB_CONF" ]; then
    write_log "Samba configuration file not found at $SMB_CONF. Samba may not be installed." "WARNING"
    write_log "Skipping configuration. Please install Samba first." "INFO"
    exit 0
fi

# Use Python to safely edit smb.conf global section
write_log "Checking Samba configuration for drift..." "INFO"

DRIFT_DETECTED=$(python3 -c '
import sys

smb_conf = sys.argv[1]
enable_smb1 = sys.argv[2] == "True" or sys.argv[2] == "true"
require_sig = sys.argv[3] == "True" or sys.argv[3] == "true"

try:
    with open(smb_conf, "r") as f:
        lines = f.readlines()
except Exception as e:
    print(f"ERROR: Failed to read smb.conf: {e}")
    sys.exit(1)

new_lines = []
in_global = False
min_proto_set = False
signing_set = False
drift = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if stripped.lower() == "[global]":
            in_global = True
        else:
            in_global = False

    if in_global:
        if stripped.startswith("server min protocol"):
            if not enable_smb1:
                if "SMB2" not in stripped and "SMB3" not in stripped:
                    line = "   server min protocol = SMB2\n"
                    min_proto_set = True
                    drift = True
                else:
                    min_proto_set = True
            else:
                min_proto_set = True
        elif stripped.startswith("server signing"):
            if require_sig:
                if "mandatory" not in stripped and "required" not in stripped:
                    line = "   server signing = mandatory\n"
                    signing_set = True
                    drift = True
                else:
                    signing_set = True
            else:
                signing_set = True

    new_lines.append(line)

# If we passed the global section and didnt find/set the values, add them
if not min_proto_set and not enable_smb1:
    for i, line in enumerate(new_lines):
        if line.strip().lower() == "[global]":
            new_lines.insert(i + 1, "   server min protocol = SMB2\n")
            drift = True
            break

if not signing_set and require_sig:
    for i, line in enumerate(new_lines):
        if line.strip().lower() == "[global]":
            new_lines.insert(i + 1, "   server signing = mandatory\n")
            drift = True
            break

if drift:
    try:
        with open(smb_conf, "w") as f:
            f.writelines(new_lines)
        print("drift_corrected")
    except Exception as e:
        print(f"ERROR: Failed to write smb.conf: {e}")
        sys.exit(1)
else:
    print("no_drift")
' "$SMB_CONF" "$ENABLE_SMB1" "$REQUIRE_SIG")

if [[ "$DRIFT_DETECTED" == *"ERROR"* ]]; then
    write_log "Failed to check/update Samba config: $DRIFT_DETECTED" "ERROR"
elif [ "$DRIFT_DETECTED" == "drift_corrected" ]; then
    write_log "Samba configuration updated to match desired state." "INFO"
    
    # Reload Samba
    if systemctl is-active --quiet smbd; then
        write_log "Reloading Samba service." "INFO"
        systemctl reload smbd
    else
        write_log "Samba service is not active. Please start it manually." "WARNING"
    fi
else
    write_log "Samba configuration already matches desired state. No action taken." "INFO"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
