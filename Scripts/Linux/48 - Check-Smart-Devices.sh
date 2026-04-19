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

write_log "Initializing SMART controller integrity audit..." "INFO"

# Admin Check (Required for smartctl on device nodes)
if [ "$EUID" -ne 0 ]; then
    write_log "⚠️ CRITICAL: Inspecting smartctl device handlers mandates privileged accounts. Please run as root." "CRITICAL"
    exit 1
fi

# Package Check for smartmontools
if ! command -v smartctl &> /dev/null; then
    write_log "smartctl not found. Attempting to install smartmontools..." "WARNING"
    if command -v apt-get &> /dev/null; then
        write_log "Updating package lists..." "INFO"
        apt-get update -y &> /dev/null
        write_log "Installing smartmontools..." "INFO"
        apt-get install -y smartmontools &> /dev/null
        if [ $? -eq 0 ]; then
            write_log "smartmontools installed successfully." "INFO"
        else
            write_log "Failed to install smartmontools. Please install manually." "CRITICAL"
            exit 1
        fi
    else
        write_log "apt-get not found. Cannot auto-install smartmontools. Please install manually." "CRITICAL"
        exit 1
    fi
fi

# Run Python helper
write_log "Running Python helper to gather SMART info..." "INFO"

python3 -c '
import sys
import os
import subprocess
import json
import datetime

log_file = sys.argv[1]
env_name = sys.argv[2]

def write_log(msg, level="INFO"):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

def bytes_2_string(bytes_val):
    for unit in ["bytes", "KB", "MB", "GB", "TB"]:
        if bytes_val < 1000.0:
            return f"{round(bytes_val, 2)} {unit}"
        bytes_val /= 1000.0
    return f"{round(bytes_val, 2)} PB"

# Check if smartctl is available
try:
    subprocess.run(["smartctl", "--version"], capture_output=True, check=True)
except:
    write_log("Cannot execute \"smartctl\". Ensure smartmontools are installed.", "CRITICAL")
    sys.exit(1)

# Scan for devices
try:
    scan_out = subprocess.check_output(["smartctl", "--scan-open"]).decode()
    for line in scan_out.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        dev = parts[0]
        
        try:
            details_out = subprocess.check_output(["smartctl", "--all", "--json", dev]).decode()
            details = json.loads(details_out)
            
            model_name = details.get("model_name", "Unknown Model")
            protocol = details.get("device", {}).get("protocol", "Unknown Protocol")
            
            capacity_str = ""
            user_capacity = details.get("user_capacity", {})
            if user_capacity:
                capacity_str = bytes_2_string(user_capacity.get("bytes", 0)) + " "
                
            temp = details.get("temperature", {}).get("current", 0)
            status = "INFO"
            infos = f"{temp}°C"
            
            if temp > 50:
                infos += " TOO HOT"
                status = "CRITICAL"
            elif temp < 0:
                infos += " TOO COLD"
                status = "WARNING"
                
            hours = details.get("power_on_time", {}).get("hours", 0)
            if hours > 87600:
                infos += f", {hours}h (!)"
                status = "WARNING"
            else:
                infos += f", {hours}h"
                
            cycles = details.get("power_cycle_count", 0)
            if cycles > 100000:
                infos += f", {cycles}x on/off (!)"
                status = "WARNING"
            else:
                infos += f", {cycles}x on/off"
                
            nvme = details.get("nvme_smart_health_information_log", {})
            if nvme:
                reads = nvme.get("data_units_read", 0) * 512 * 1000
                writes = nvme.get("data_units_written", 0) * 512 * 1000
                infos += f", {bytes_2_string(reads)} read"
                infos += f", {bytes_2_string(writes)} written"
                
            firmware = details.get("firmware_version", "Unknown")
            infos += f", v{firmware}"
            
            passed = details.get("smart_status", {}).get("passed", False)
            if passed:
                infos += ", test passed"
            else:
                infos += ", test FAILED"
                status = "CRITICAL"
                
            write_log(f"{capacity_str}{model_name} via {protocol} ({infos})", status)
            
            try:
                subprocess.run(["smartctl", "--test=conveyance", dev], capture_output=True)
            except:
                pass
                
        except Exception as e:
            write_log(f"Failed to query device {dev}: {e}", "ERROR")
            
except Exception as e:
    write_log(f"Failed to scan devices: {e}", "CRITICAL")
    sys.exit(1)

' "$LOG_FILE" "$ENVIRONMENT"

if [ $? -eq 0 ]; then
    write_log "Smart sensor checks completed successfully." "INFO"
else
    write_log "Smart sensor checks failed." "ERROR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
