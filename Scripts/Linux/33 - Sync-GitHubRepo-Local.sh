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

REPO_URL=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('RepoUrl', ''))" "$CONFIG_JSON")
BRANCH=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('Branch', 'main'))" "$CONFIG_JSON")
LOCAL_REPO_PATH=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('LocalRepoPath', ''))" "$CONFIG_JSON")
GIT_TOKEN=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('Token', ''))" "$CONFIG_JSON")

# Translate path if it looks like Windows
if [[ "$LOCAL_REPO_PATH" == *":"* ]]; then
    REPO_NAME=$(basename "$LOCAL_REPO_PATH")
    LOCAL_REPO_PATH="$BASE_DIR/Git/$REPO_NAME"
    write_log "Translated Windows path to Linux: $LOCAL_REPO_PATH" "INFO"
fi

write_log "Loaded Configuration Variables:" "INFO"
write_log "  RepoUrl = $REPO_URL" "INFO"
write_log "  Branch = $BRANCH" "INFO"
write_log "  LocalRepoPath = $LOCAL_REPO_PATH" "INFO"

if [ -z "$REPO_URL" ] || [ -z "$LOCAL_REPO_PATH" ]; then
    write_log "FATAL: Missing required config (RepoUrl or LocalRepoPath)." "CRITICAL"
    exit 1
fi

# Handle Token for Auth
AUTH_URL="$REPO_URL"
if [ -n "$GIT_TOKEN" ]; then
    AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://$GIT_TOKEN@|")
    write_log "Using provided token for authentication." "INFO"
else
    write_log "WARNING: No Git Token provided in config. Attempting public access or relying on cached credentials." "WARNING"
fi

# Git Environment Check
if ! command -v git &> /dev/null; then
    write_log "FATAL: Git is not installed." "CRITICAL"
    exit 1
fi

# Clone / Pull
if [ ! -d "$LOCAL_REPO_PATH/.git" ]; then
    write_log "Cloning repository..." "INFO"
    mkdir -p "$LOCAL_REPO_PATH"
    git clone -b "$BRANCH" "$AUTH_URL" "$LOCAL_REPO_PATH"
    
    if [ $? -ne 0 ]; then
        write_log "Failed to clone repository." "CRITICAL"
        exit 1
    fi
else
    write_log "Repository exists. Fetching and resetting..." "INFO"
    cd "$LOCAL_REPO_PATH"
    git fetch --quiet "$AUTH_URL" "$BRANCH"
    
    LOCAL_HASH=$(git rev-parse HEAD)
    REMOTE_HASH=$(git rev-parse FETCH_HEAD)
    
    write_log "Local: $LOCAL_HASH, Remote: $REMOTE_HASH" "INFO"
    
    git reset --hard FETCH_HEAD
    
    if [ $? -ne 0 ]; then
        write_log "Failed to reset repository to remote state." "CRITICAL"
        exit 1
    fi
fi

# File Replication to Operating Folders
# The user requested to sync ALL files regardless if changes happened or not.
# We use rsync with --ignore-times to force copying everything.
# We must exclude the source directory (Git/) and .git to avoid a copy loop!
write_log "Syncing all files from staging to base directory..." "INFO"

if command -v rsync &> /dev/null; then
    # Trailing slash on source is critical to copy contents, not the folder itself
    rsync -av --ignore-times --exclude='.git' --exclude='Git/' "$LOCAL_REPO_PATH/" "$BASE_DIR/"
    
    if [ $? -eq 0 ]; then
        write_log "Sync completed successfully via rsync." "INFO"
    else
        write_log "Rsync failed." "ERROR"
    fi
else
    write_log "rsync not found. Falling back to Python copy." "WARNING"
    
    python3 -c '
import shutil
import os
import sys

src = sys.argv[1]
dst = sys.argv[2]

def ignore_func(dir, contents):
    return [c for c in contents if c in [".git", "Git"]]

try:
    for item in os.listdir(src):
        s = os.path.join(src, item)
        d = os.path.join(dst, item)
        if item in [".git", "Git"]:
            continue
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True, ignore=ignore_func)
        else:
            shutil.copy2(s, d)
    print("Sync completed successfully via Python.")
except Exception as e:
    print(f"ERROR: Failed to sync files: {e}")
' "$LOCAL_REPO_PATH" "$BASE_DIR"
fi

write_log "Script execution completed successfully." "INFO"
post_flight
