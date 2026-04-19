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
    body = f"The following errors were detected in the {script_name} run:\n\n" + "".join(errors)
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

write_log "Running Python helper to test network connectivity..." "INFO"

python3 -c '
import json
import sys
import subprocess
import re
import datetime

config_json = sys.argv[1]
log_file = sys.argv[2]
env_name = sys.argv[3]

try:
    config = json.loads(config_json)
except:
    config = {}

gateway = config.get("GatewayIP", "192.168.1.1")
count = config.get("PingCount", 4)
required_rate = config.get("RequiredSuccessRate", 75)

def write_log(msg, level="INFO"):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

write_log(f"Testing connectivity to Gateway: {gateway}", "INFO")

try:
    output = subprocess.check_output(["ping", "-c", str(count), gateway], stderr=subprocess.STDOUT).decode()
    
    match = re.search(r"(\d+) packets transmitted, (\d+) received", output)
    if match:
        transmitted = int(match.group(1))
        received = int(match.group(2))
        success_rate = (received / transmitted) * 100
        
        write_log(f"Success rate: {success_rate}% ({received}/{transmitted} received)", "INFO")
        
        if success_rate >= required_rate:
            write_log("Network check passed.", "INFO")
            sys.exit(0)
        else:
            write_log(f"Network check failed. Success rate: {success_rate}%. Gateway unreachable.", "CRITICAL")
            sys.exit(1)
    else:
        write_log("Failed to parse ping output.", "ERROR")
        sys.exit(1)
        
except subprocess.CalledProcessError as e:
    output = e.output.decode()
    match = re.search(r"(\d+) packets transmitted, (\d+) received", output)
    if match:
        transmitted = int(match.group(1))
        received = int(match.group(2))
        success_rate = (received / transmitted) * 100
        write_log(f"Success rate: {success_rate}% ({received}/{transmitted} received)", "INFO")
        if success_rate >= required_rate:
            write_log("Network check passed.", "INFO")
            sys.exit(0)
        else:
            write_log(f"Network check failed. Success rate: {success_rate}%. Gateway unreachable.", "CRITICAL")
            sys.exit(1)
    else:
        write_log(f"Ping failed: {output}", "CRITICAL")
        sys.exit(1)
except Exception as e:
    write_log(f"Script encountered an error: {e}", "CRITICAL")
    sys.exit(1)
' "$CONFIG_JSON" "$LOG_FILE" "$ENVIRONMENT"

if [ $? -eq 0 ]; then
    write_log "Network connectivity test completed successfully." "INFO"
else
    write_log "Network connectivity test failed." "ERROR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
