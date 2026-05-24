#!/bin/bash

# Script Name
SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOG_FILE="$BASE_DIR/Logs/$SCRIPT_NAME.log"
CONFIG_FILE="$BASE_DIR/Variables/000 - Bootstrap.json"
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

write_log "Initializing Bootstrap script execution." "INFO"

# Verify target script folder exists
if [ ! -d "$SCRIPT_DIR" ]; then
    write_log "The script folder $SCRIPT_DIR does not exist." "CRITICAL"
    exit 1
fi

# Dependency Checks
write_log "Performing dependency checks..." "INFO"
if ! command -v python3 &> /dev/null; then
    write_log "python3 is missing. Please install it." "CRITICAL"
    exit 1
fi

if ! command -v crontab &> /dev/null; then
    write_log "crontab command not found. Please ensure cron is installed." "CRITICAL"
    exit 1
fi

# Read config and setup cron
python3 -c '
import sys
import json
import os
import subprocess

script_dir = sys.argv[1]
config_file = sys.argv[2]
global_file = sys.argv[3]

try:
    with open(config_file, "r") as f:
        config = json.load(f)
except Exception as e:
    print(f"CRITICAL: Failed to load config: {e}")
    sys.exit(1)

scripts_config = config.get("ScriptsConfig", [])
config_map = {}
for c in scripts_config:
    key = c["ScriptName"].replace(".ps1", "")
    config_map[key] = c
    if "LinuxName" in c:
        linux_key = c["LinuxName"].replace(".sh", "")
        config_map[linux_key] = c

# Get current crontab
try:
    current_cron = subprocess.check_output(["crontab", "-l"], stderr=subprocess.DEVNULL).decode("utf-8")
except subprocess.CalledProcessError:
    current_cron = ""

new_cron_lines = []
current_lines = current_cron.splitlines()

# Filter out existing auto-generated tasks to avoid duplicates
for line in current_lines:
    if "# AutoRun_" not in line:
        new_cron_lines.append(line)

# Find all .sh scripts
for root, dirs, files in os.walk(script_dir):
    for file in files:
        if file.endswith(".sh") and file != "000 - Bootstrap Script.sh":
            base_name = file.replace(".sh", "")
            script_path = os.path.join(root, file)
            
            # Find interval
            interval = 1440 # Default daily
            if base_name in config_map:
                interval = config_map[base_name].get("IntervalMinutes", 1440)
            
            # Map interval to cron
            cron_expr = "0 0 * * *" # Daily
            if interval == 2:
                cron_expr = "*/2 * * * *"
            elif interval == 15:
                cron_expr = "*/15 * * * *"
            elif interval == 60:
                cron_expr = "0 * * * *"
            elif interval == 1440:
                cron_expr = "0 0 * * *"
            elif interval == 10080:
                cron_expr = "0 0 * * 0"
            
            cron_line = f"{cron_expr} {script_path} # AutoRun_{base_name}"
            new_cron_lines.append(cron_line)
            print(f"INFO: Scheduled {file} with interval {interval} mins ({cron_expr})")

# Update crontab
cron_text = "\n".join(new_cron_lines) + "\n"
process = subprocess.Popen(["crontab", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
stdout, stderr = process.communicate(input=cron_text.encode("utf-8"))

if process.returncode != 0:
    print(f"CRITICAL: Failed to update crontab: {stderr.decode('utf-8')}")
    sys.exit(1)
else:
    print("INFO: Crontab updated successfully.")
' "$SCRIPT_DIR" "$CONFIG_FILE" "$GLOBAL_FILE"

write_log "Bootstrap script execution completed." "INFO"
post_flight
