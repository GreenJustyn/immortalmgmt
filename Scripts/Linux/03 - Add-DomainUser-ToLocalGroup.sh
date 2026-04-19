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
global_file = sys.argv[2]
script_name = sys.argv[3]

# Load global config for email
try:
    with open(global_file, "r") as f:
        config = json.load(f)
except Exception as e:
    print(f"CRITICAL: Failed to load global config: {e}")
    sys.exit(1)

email_to = config.get("EmailTo")
email_from = config.get("EmailFrom")
app_password = config.get("EmailAppPassword")

if not all([email_to, email_from, app_password]):
    print("WARNING: Email config missing in _Global.json.")
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
    body = f"Trigger Warning recorded on {script_name}:\n\n" + "".join(errors)
    msg = MIMEText(body)
    msg["Subject"] = f"Alert: Script Event Failure"
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
' "$LOG_FILE" "$GLOBAL_FILE" "$SCRIPT_NAME"
        
    else
        write_log "Log file not found at $LogFile. Cannot scan for errors." "WARNING"
    fi
}

write_log "Initializing group membership enforcement..." "INFO"

# Admin Check
if [ "$EUID" -ne 0 ]; then
    write_log "⚠️ CRITICAL: Modifying group memberships requires root privileges." "CRITICAL"
    exit 1
fi

# Run Python helper
write_log "Running Python helper to apply group membership..." "INFO"

python3 -c '
import sys
import json
import subprocess
import os

config_file = sys.argv[1]
log_file = sys.argv[2]
env_name = sys.argv[3]

def write_log(msg, level="INFO"):
    import datetime
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

try:
    with open(config_file, "r") as f:
        config = json.load(f)
except Exception as e:
    write_log(f"Failed to load config: {e}", "CRITICAL")
    sys.exit(1)

local_group = config.get("LocalGroup", "Administrators")
domain_user = config.get("DomainUser", "")

if not domain_user:
    write_log("No DomainUser specified in config.", "ERROR")
    sys.exit(1)

# Map Administrators to Linux equivalent
if local_group == "Administrators":
    if os.path.exists("/etc/debian_version"):
        local_group = "sudo"
    else:
        local_group = "wheel"

write_log(f"Mapped \"Administrators\" to Linux group \"{local_group}\"", "INFO")

user_to_add = domain_user

write_log(f"Attempting to add user \"{user_to_add}\" to group \"{local_group}\"...", "INFO")

try:
    subprocess.run(["id", user_to_add], check=True, capture_output=True)
except subprocess.CalledProcessError:
    write_log(f"User \"{user_to_add}\" does not exist or cannot be found. SSSD might not be configured.", "WARNING")
    
try:
    result = subprocess.run(["usermod", "-aG", local_group, user_to_add], capture_output=True, text=True)
    if result.returncode == 0:
        write_log(f"Successfully added user \"{user_to_add}\" to group \"{local_group}\".", "INFO")
    else:
        write_log(f"Failed to add user to group: {result.stderr.strip()}", "ERROR")
        sys.exit(1)
except Exception as e:
    write_log(f"Exception occurred during usermod: {e}", "ERROR")
    sys.exit(1)
' "$CONFIG_FILE" "$LOG_FILE" "$ENVIRONMENT"

if [ $? -eq 0 ]; then
    write_log "Group membership enforcement completed." "INFO"
else
    write_log "Group membership enforcement failed." "ERROR"
fi

post_flight
