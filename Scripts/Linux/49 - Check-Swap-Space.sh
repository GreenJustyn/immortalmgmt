#!/bin/bash

# Script Name
SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

LOG_FILE="$BASE_DIR/Logs/$SCRIPT_NAME.log"
CONFIG_FILE="$BASE_DIR/Variables/$SCRIPT_NAME.json"
GLOBAL_FILE="$BASE_DIR/Variables/_Global.json"

ENVIRONMENT="#{ENVIRONMENT}#"

# Support parameter passing
MIN_LEVEL="${1:-10}"

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

write_log "Initializing logical paging usage levels..." "INFO"

# Run Python helper
write_log "Running Python helper to gather swap info..." "INFO"

python3 -c '
import sys
import os
import datetime

log_file = sys.argv[1]
env_name = sys.argv[2]
min_level = int(sys.argv[3])

def write_log(msg, level="INFO"):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

def mb_2_string(mb_val):
    if mb_val < 1024:
        return f"{round(mb_val, 2)} MB"
    mb_val /= 1024
    if mb_val < 1024:
        return f"{round(mb_val, 2)} GB"
    mb_val /= 1024
    return f"{round(mb_val, 2)} TB"

swap_total = 0
swap_free = 0

try:
    with open("/proc/meminfo", "r") as f:
        for line in f:
            if line.startswith("SwapTotal:"):
                swap_total = int(line.split()[1]) // 1024 # Convert KB to MB
            elif line.startswith("SwapFree:"):
                swap_free = int(line.split()[1]) // 1024
except Exception as e:
    write_log(f"Failed to read /proc/meminfo: {e}", "ERROR")
    sys.exit(1)

swap_used = swap_total - swap_free

status = "INFO"
msg = ""

if swap_total == 0:
    msg = "⚠️ No swap space configured."
    status = "WARNING"
elif swap_free == 0:
    msg = f"⚠️ Swap space of {mb_2_string(swap_total)} is fully saturated!"
    status = "CRITICAL"
elif swap_free < min_level:
    msg = f"⚠️ Swap space has only {mb_2_string(swap_free)} of {mb_2_string(swap_total)} left!"
    status = "WARNING"
elif swap_used < 3:
    msg = f"✅ Swap space has {mb_2_string(swap_total)} explicitly available."
else:
    percent = int((swap_used * 100) / swap_total)
    msg = f"✅ Swap space actively consuming {percent}% of {mb_2_string(swap_total)} ({mb_2_string(swap_free)} available)"

write_log(msg, status)
' "$LOG_FILE" "$ENVIRONMENT" "$MIN_LEVEL"

if [ $? -eq 0 ]; then
    write_log "Swap check completed successfully." "INFO"
else
    write_log "Swap check failed." "ERROR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
