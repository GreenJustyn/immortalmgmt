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

write_log "Initializing script execution: CPU Inventory & Thermal Checks." "INFO"

# Run Python helper
write_log "Running Python helper to gather CPU info..." "INFO"

python3 -c '
import sys
import os
import platform
import datetime
import re

log_file = sys.argv[1]
env_name = sys.argv[2]

def write_log(msg, level="INFO"):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

# 1. CPU Name and Cores
cpu_name = platform.processor() or "Unknown CPU"
cores = os.cpu_count() or 0

# Try to get more detailed name from /proc/cpuinfo on Linux
if os.path.exists("/proc/cpuinfo"):
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if "model name" in line:
                    cpu_name = line.split(":")[1].strip()
                    break
    except:
        pass

# 2. Temperature
celsius = 99999.9 # Unsupported default

# Try thermal zone (Pi)
if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            celsius = round(float(f.read().strip()) / 1000.0, 1)
    except:
        pass
# Try hwmon (x86) if still unsupported
elif os.path.exists("/sys/class/hwmon"):
    try:
        for h in os.listdir("/sys/class/hwmon"):
            temp_path = os.path.join("/sys/class/hwmon", h, "temp1_input")
            if os.path.exists(temp_path):
                with open(temp_path, "r") as f:
                    celsius = round(float(f.read().strip()) / 1000.0, 1)
                    break
    except:
        pass

# 3. Evaluate Thresholds
status = "INFO"
temp_str = ""

if celsius == 99999.9:
    temp_str = ""
elif celsius > 80:
    temp_str = f", {celsius}°C TOO HOT"
    status = "CRITICAL"
elif celsius > 50:
    temp_str = f", {celsius}°C HOT"
    status = "WARNING"
elif celsius < 0:
    temp_str = f", {celsius}°C TOO COLD"
    status = "WARNING"
else:
    temp_str = f", {celsius}°C"

write_log(f"{cpu_name} ({cores} cores{temp_str})", status)
' "$LOG_FILE" "$ENVIRONMENT"

if [ $? -eq 0 ]; then
    write_log "CPU check completed successfully." "INFO"
else
    write_log "CPU check failed." "ERROR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
