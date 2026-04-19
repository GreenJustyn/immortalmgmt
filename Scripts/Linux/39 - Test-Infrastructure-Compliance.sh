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
    body = f"The following compliance failures or script errors were detected in the {script_name} run:\n\n" + "".join(errors)
    msg = MIMEText(body)
    msg["Subject"] = f"Script Alert: {script_name} Compliance Failures"
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

write_log "Initializing script execution." "INFO"

# Load Config
if [ ! -f "$CONFIG_FILE" ]; then
    write_log "FATAL: Config file missing at $CONFIG_FILE." "CRITICAL"
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

write_log "Running Python helper to execute compliance tests..." "INFO"

python3 -c '
import os
import sys
import json
import subprocess
import datetime

config_json = sys.argv[1]
base_dir = sys.argv[2]
log_file = sys.argv[3]
env_name = sys.argv[4]

try:
    config = json.loads(config_json)
except:
    config = {}

scripts_dir = os.path.join(base_dir, "Scripts/Linux")
config_dir = os.path.join(base_dir, "Variables")

def write_log(msg, level="INFO"):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

write_log("Starting Infrastructure Compliance Tests...", "INFO")

failures = 0

# 1. Static Code Analysis
if os.path.exists(scripts_dir):
    for root, dirs, files in os.walk(scripts_dir):
        for file in files:
            if file.endswith(".sh"):
                filepath = os.path.join(root, file)
                # Syntax check
                res = subprocess.run(["bash", "-n", filepath], capture_output=True)
                if res.returncode != 0:
                    write_log(f"Syntax error in {file}: {res.stderr.decode().strip()}", "ERROR")
                    failures += 1
                
                # Config check
                basename = os.path.splitext(file)[0]
                config_path = os.path.join(config_dir, f"{basename}.json")
                if not os.path.exists(config_path):
                    write_log(f"Warning: Missing JSON config file for {file}.", "WARNING")

# 2. Critical Services
res = subprocess.run(["systemctl", "is-active", "--quiet", "ssh"])
if res.returncode != 0:
    write_log("Compliance Failure: SSH Service is not running.", "ERROR")
    failures += 1

# 3. Master Logs directory
logs_dir = os.path.join(base_dir, "Logs")
if not os.path.exists(logs_dir):
    write_log("Compliance Failure: Directory Logs/ missing.", "ERROR")
    failures += 1

# 4. Break-Glass account
config30_path = os.path.join(config_dir, "30 - New-LocalAdminAccount.json")
account_name = "BreakGlass" # Default
if os.path.exists(config30_path):
    try:
        with open(config30_path, "r") as f:
            c30 = json.load(f)
            account_name = c30.get("AccountName", account_name)
    except:
        pass

try:
    import pwd
    pwd.getpwnam(account_name)
except KeyError:
    write_log(f"Compliance Failure: Account {account_name} is missing.", "ERROR")
    failures += 1

if failures > 0:
    write_log(f"Compliance tests failed with {failures} errors.", "ERROR")
    sys.exit(1)
else:
    write_log("All compliance tests passed.", "INFO")
    sys.exit(0)
' "$CONFIG_JSON" "$BASE_DIR" "$LOG_FILE" "$ENVIRONMENT"

if [ $? -eq 0 ]; then
    write_log "Compliance tests completed successfully." "INFO"
else
    write_log "Compliance tests detected failures." "ERROR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
