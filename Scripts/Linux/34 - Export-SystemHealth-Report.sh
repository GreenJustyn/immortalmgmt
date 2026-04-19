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

REPORT_PATH=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('ReportPath', ''))" "$CONFIG_JSON")
THRESHOLD=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('DiskWarningThresholdPercent', 15))" "$CONFIG_JSON")

# Translate path if it looks like Windows
if [[ "$REPORT_PATH" == *":"* ]]; then
    REPORT_PATH="$BASE_DIR/Logs/Health/HealthReport.html"
    write_log "Translated Windows path to Linux: $REPORT_PATH" "INFO"
fi

write_log "Loaded Configuration Variables:" "INFO"
write_log "  ReportPath = $REPORT_PATH" "INFO"
write_log "  DiskWarningThresholdPercent = $THRESHOLD" "INFO"

# Create directory for report if it doesn't exist
mkdir -p "$(dirname "$REPORT_PATH")"

# Run Python script to gather data and generate report
write_log "Running Python helper to compile system health data..." "INFO"

python3 -c '
import sys
import os
import json
import shutil
import datetime
import subprocess

config_json = sys.argv[1]
report_path = sys.argv[2]
log_file = sys.argv[3]
env_name = sys.argv[4]

try:
    config = json.loads(config_json)
except:
    config = {}

threshold = float(config.get("DiskWarningThresholdPercent", 15))

def write_log(msg, level="INFO"):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{timestamp}] [{level}] [{env_name}] {msg}\n")
    print(f"[{level}] {msg}")

# 1. Uptime
try:
    with open("/proc/uptime", "r") as f:
        uptime_seconds = float(f.readline().split()[0])
    uptime_days = int(uptime_seconds // (24 * 3600))
    uptime_hours = int((uptime_seconds % (24 * 3600)) // 3600)
except:
    uptime_days = 0
    uptime_hours = 0

uptime_str = f"{uptime_days} Days, {uptime_hours} Hours"

# 2. Disk Space
usage = shutil.disk_usage("/")
total_gb = round(usage.total / (1024**3), 2)
free_gb = round(usage.free / (1024**3), 2)
free_pct = round((usage.free / usage.total) * 100, 2)

# 3. Generate HTML
html_head = "<style>body{font-family: Arial;} table{border-collapse: collapse; width: 50%;} th, td{border: 1px solid #ddd; padding: 8px;} th{background-color: #f2f2f2;}</style>"
html_body = f"<h2>[{env_name}] System Health Report - {os.uname().nodename}</h2>"
html_body += f"<p><strong>Uptime:</strong> {uptime_str}</p>"
html_body += "<h3>Disk Space</h3>"
html_body += "<table><tr><th>Drive</th><th>FreeGB</th><th>TotalGB</th><th>FreePct</th></tr>"
html_body += f"<tr><td>/</td><td>{free_gb}</td><td>{total_gb}</td><td>{free_pct}</td></tr></table>"

# 4. Check Threshold and Find Large Files
if free_pct < threshold:
    write_log(f"Disk / has less than {threshold}% free space ({free_pct}% remaining).", "ERROR")
    
    write_log("Initiating scan for top 5 largest files...", "INFO")
    try:
        # Find top 5 largest files in / avoiding virtual filesystems
        cmd = "find / -type f -exec du -h {} + 2>/dev/null | sort -rh | head -n 5"
        output = subprocess.check_output(cmd, shell=True).decode()
        write_log("Top 5 largest space consumers on Drive /:", "ERROR")
        for line in output.splitlines():
            write_log(f"  {line}", "ERROR")
    except Exception as e:
        write_log(f"Failed to scan for large files: {e}", "WARNING")

# Write Report
try:
    with open(report_path, "w") as f:
        f.write(f"<html><head>{html_head}</head><body>{html_body}</body></html>")
    write_log(f"HTML Health Report successfully exported to {report_path}.", "INFO")
except Exception as e:
    write_log(f"Failed to generate HTML report: {e}", "ERROR")
    sys.exit(1)

# 5. Purge Temp Files (7 days)
temp_dir = "/tmp"
cutoff = datetime.datetime.now() - datetime.timedelta(days=7)
purged = 0

write_log(f"Checking {temp_dir} for files older than 7 days...", "INFO")
try:
    for root, dirs, files in os.walk(temp_dir):
        for file in files:
            filepath = os.path.join(root, file)
            try:
                mtime = datetime.datetime.fromtimestamp(os.path.getmtime(filepath))
                if mtime < cutoff:
                    os.remove(filepath)
                    purged += 1
            except:
                pass
    if purged > 0:
        write_log(f"Purged {purged} aged temporary files from {temp_dir}.", "INFO")
    else:
        write_log(f"No files older than 7 days found in {temp_dir}.", "INFO")
except Exception as e:
    write_log(f"Failed to purge temp files: {e}", "WARNING")

' "$CONFIG_JSON" "$REPORT_PATH" "$LOG_FILE" "$ENVIRONMENT"

write_log "Script execution completed successfully." "INFO"
post_flight
