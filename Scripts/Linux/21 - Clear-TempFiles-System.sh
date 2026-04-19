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
        write_log "Log file not found at $LOG_FILE. Cannot scan for errors." "WARNING"
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

DIRECTORIES=$(python3 -c "import json, sys; print(' '.join(json.loads(sys.argv[1]).get('DirectoriesToClean', [])))" "$CONFIG_JSON")
MAX_AGE_DAYS=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('MaxAgeDays', 14))" "$CONFIG_JSON")

write_log "Loaded Configuration Variables:" "INFO"
write_log "  DirectoriesToClean = $DIRECTORIES" "INFO"
write_log "  MaxAgeDays = $MAX_AGE_DAYS" "INFO"

TOTAL_DELETED=0

for dir in $DIRECTORIES; do
    # Map Windows paths to Linux
    if [[ "$dir" =~ ^[a-zA-Z]:\\ ]]; then
        NEW_PATH=$(echo "$dir" | sed 's/^[a-zA-Z]:\\/\//' | tr '\\' '/')
        write_log "Mapping Windows path $dir to Linux path $NEW_PATH" "INFO"
        dir="$NEW_PATH"
    fi
    
    # Handle specific common mappings
    if [[ "$dir" == "/Windows/Temp" ]]; then
        write_log "Mapping /Windows/Temp to /tmp" "INFO"
        dir="/tmp"
    fi

    if [ -d "$dir" ]; then
        write_log "Scanning $dir for files older than $MAX_AGE_DAYS days..." "INFO"
        
        # Count files to be deleted (using find and wc)
        COUNT=$(find "$dir" -type f -mtime +"$MAX_AGE_DAYS" 2>/dev/null | wc -l)
        
        if [ "$COUNT" -gt 0 ]; then
            write_log "Found $COUNT files to delete." "INFO"
            # Delete files
            find "$dir" -type f -mtime +"$MAX_AGE_DAYS" -delete 2>/dev/null
            TOTAL_DELETED=$((TOTAL_DELETED + COUNT))
            write_log "Deleted $COUNT files from $dir." "INFO"
        else
            write_log "No old files found in $dir." "INFO"
        fi
    else
        write_log "Directory $dir does not exist. Skipping." "WARNING"
    fi
done

write_log "Cleanup complete. Successfully removed $TOTAL_DELETED old files." "INFO"
write_log "Script execution completed successfully." "INFO"
post_flight
