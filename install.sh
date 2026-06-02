#!/bin/bash

# Script Name
SCRIPT_NAME="install"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$SCRIPT_DIR"

LOGS_DIR="$BASE_DIR/Logs"
if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR"
fi

LOG_FILE="$LOGS_DIR/$SCRIPT_NAME.log"
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

write_log "Initializing Guided Install wizard." "INFO"

echo -e "\e[36m================================================================="
echo -e "      IMMORTALMGMT AUTOMATION FRAMEWORK INSTALLATION WIZARD      "
echo -e "=================================================================\e[0m"
echo ""

# =====================================================================
# Step 1: Installation Directory Setup & File Migration
# =====================================================================
echo -e "\e[32m[STEP 1] Target Installation Path Setup\e[0m"
DEFAULT_PATH="/opt/immortalmgmt"
read -p "Enter target installation directory [Default: $DEFAULT_PATH]: " USER_PATH
INSTALL_PATH="${USER_PATH:-$DEFAULT_PATH}"

write_log "Target installation path resolved to: $INSTALL_PATH" "INFO"

if [ "$INSTALL_PATH" != "$BASE_DIR" ]; then
    echo -e "\e[90mCreating directory and migrating files to $INSTALL_PATH...\e[0m"
    mkdir -p "$INSTALL_PATH"
    
    # Copy all files except log files
    rsync -a --exclude='*.log' "$BASE_DIR/" "$INSTALL_PATH/"
    
    # Update variables for rest of setup
    BASE_DIR="$INSTALL_PATH"
    LOGS_DIR="$BASE_DIR/Logs"
    mkdir -p "$LOGS_DIR"
    LOG_FILE="$LOGS_DIR/$SCRIPT_NAME.log"
    GLOBAL_FILE="$BASE_DIR/Variables/_Global.json"
    echo -e "\e[32mFiles migrated successfully to $INSTALL_PATH.\e[0m"
else
    echo -e "\e[32mRunning installation in-place at $BASE_DIR.\e[0m"
fi

# =====================================================================
# Step 2: Dependency Checks
# =====================================================================
echo ""
echo -e "\e[32m[STEP 2] Performing dependency checks...\e[0m"
if ! command -v python3 &> /dev/null; then
    write_log "python3 is missing. Please install it." "CRITICAL"
    exit 1
else
    write_log "python3 is available." "INFO"
fi

# =====================================================================
# Step 3: Global Configuration Setup (Email Alerting)
# =====================================================================
echo ""
echo -e "\e[32m[STEP 3] Global Configuration Setup (Email Alerting)\e[0m"
read -p "Do you want to configure email alerts now? (Y/N) [Default: Y]: " CONFIRM_EMAIL
CONFIRM_EMAIL="${CONFIRM_EMAIL:-Y}"

EMAIL_TO=""
EMAIL_FROM=""
EMAIL_APP_PASSWORD=""

if [[ "$CONFIRM_EMAIL" =~ ^[Yy]$ ]]; then
    read -p "  Enter alert recipient email address (EmailTo): " EMAIL_TO
    read -p "  Enter alert sender email address (EmailFrom): " EMAIL_FROM
    read -p "  Enter App-Specific Gmail Password (EmailAppPassword): " EMAIL_APP_PASSWORD
fi

# Update Global Config using inline python
python3 -c '
import sys
import json
import os

global_file = sys.argv[1]
email_to = sys.argv[2]
email_from = sys.argv[3]
app_pwd = sys.argv[4]

config = {
    "EmailTo": email_to,
    "EmailFrom": email_from,
    "EmailAppPassword": app_pwd
}

os.makedirs(os.path.dirname(global_file), exist_ok=True)
with open(global_file, "w") as f:
    json.dump(config, f, indent=4)
' "$GLOBAL_FILE" "$EMAIL_TO" "$EMAIL_FROM" "$EMAIL_APP_PASSWORD"

write_log "Created / Updated global configuration at $GLOBAL_FILE." "INFO"

# =====================================================================
# Step 4: Host Inventory Setup
# =====================================================================
echo ""
echo -e "\e[32m[STEP 4] Host Inventory Setup\e[0m"
HOSTNAME=$(hostname)
write_log "Identified local hostname: $HOSTNAME" "INFO"

HOSTS_DIR="$BASE_DIR/Variables/Hosts"
HOST_DIR="$HOSTS_DIR/$HOSTNAME"
mkdir -p "$HOST_DIR"

DEFAULT_HOST_DIR="$HOSTS_DIR/DefaultHost"
if [ -d "$DEFAULT_HOST_DIR" ]; then
    for file in "$DEFAULT_HOST_DIR"/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            dest_file="$HOST_DIR/$filename"
            if [ ! -f "$dest_file" ]; then
                cp "$file" "$dest_file"
            fi
        fi
    done
fi

KEEP_FILE="$HOST_DIR/.keep"
if [ ! -f "$KEEP_FILE" ]; then
    echo "This folder is for host $HOSTNAME variables." > "$KEEP_FILE"
fi

# Gather detailed system info and save in _Host.json using Python
python3 -c '
import sys
import os
import datetime
import json
import platform

host_dir = sys.argv[1]
hostname = sys.argv[2]

host_vars_file = os.path.join(host_dir, "_Host.json")

try:
    # OS Info
    os_name = "Unknown"
    os_version = "Unknown"
    if os.path.exists("/etc/os-release"):
        with open("/etc/os-release", "r") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    os_name = line.split("=")[1].strip().strip("\"")
                elif line.startswith("VERSION="):
                    os_version = line.split("=")[1].strip().strip("\"")
                    
    # CPU Info
    cpu_name = "Unknown"
    if os.path.exists("/proc/cpuinfo"):
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("model name"):
                    cpu_name = line.split(":")[1].strip()
                    break
                    
    # RAM Info
    ram_gb = 0
    if os.path.exists("/proc/meminfo"):
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_kb = int(line.split()[1])
                    ram_gb = round(mem_kb / (1024 * 1024), 2)
                    break
                    
    # IP and MAC
    ip_addresses = []
    mac_addresses = []
    try:
        import subprocess
        ip_out = subprocess.check_output(["hostname", "-I"]).decode()
        ip_addresses = [ip for ip in ip_out.split() if not ip.startswith("127.")]
        
        for dev in os.listdir("/sys/class/net"):
            if dev != "lo":
                with open(f"/sys/class/net/{dev}/address", "r") as f:
                    mac_addresses.append(f.read().strip())
    except:
        pass
        
    # Timezone
    tz = "Unknown"
    try:
        tz = subprocess.check_output(["timedatectl", "show", "--property=Timezone", "--value"]).decode().strip()
    except:
        if os.path.exists("/etc/timezone"):
            with open("/etc/timezone", "r") as f:
                tz = f.read().strip()
                
    host_vars = {
        "HostName": hostname,
        "OSName": os_name,
        "OSVersion": os_version,
        "OSArchitecture": platform.machine(),
        "CPU": cpu_name,
        "RAM_GB": ram_gb,
        "IPAddresses": ip_addresses,
        "MACAddresses": mac_addresses,
        "TimeZone": tz,
        "Domain": "Unknown",
        "InstallDate": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    }
    
    with open(host_vars_file, "w") as f:
        json.dump(host_vars, f, indent=4)
except Exception as e:
    print(f"ERROR: Failed to gather system info: {e}")
    sys.exit(1)
' "$HOST_DIR" "$HOSTNAME"

write_log "Created thorough set of host variables in _Host.json" "INFO"

# Update .gitignore
GITIGNORE_FILE="$BASE_DIR/.gitignore"
IGNORE_ENTRY="Variables/Hosts/$HOSTNAME/"
if [ -f "$GITIGNORE_FILE" ]; then
    if ! grep -q "$IGNORE_ENTRY" "$GITIGNORE_FILE"; then
        echo "$IGNORE_ENTRY" >> "$GITIGNORE_FILE"
    fi
else
    echo "$IGNORE_ENTRY" > "$GITIGNORE_FILE"
fi

# =====================================================================
# Step 5: Environment Variable Validation
# =====================================================================
echo ""
echo -e "\e[32m[STEP 5] Environment Variable Validation\e[0m"
echo "Select framework environment to configure:"
echo "  1) Production"
echo "  2) Staging"
echo "  3) Development"
echo "  4) Custom"
read -p "Enter choice (1-4) [Default: 1]: " ENV_CHOICE
ENV_CHOICE="${ENV_CHOICE:-1}"

case "$ENV_CHOICE" in
    1) RESOLVED_ENV="Production" ;;
    2) RESOLVED_ENV="Staging" ;;
    3) RESOLVED_ENV="Development" ;;
    4) read -p "Enter custom environment name: " CUSTOM_ENV; RESOLVED_ENV="$CUSTOM_ENV" ;;
    *) RESOLVED_ENV="Production" ;;
esac

RESOLVED_ENV="${RESOLVED_ENV:-Production}"
ENVIRONMENT="$RESOLVED_ENV"
write_log "Resolved environment context: $ENVIRONMENT" "INFO"

# Replace environment placeholder recursively using python for absolute cross-platform safety
echo -e "\e[90mEnforcing environment context across script files...\e[0m"
python3 -c '
import sys
import os

base_dir = sys.argv[1]
resolved_env = sys.argv[2]

for root, dirs, files in os.walk(base_dir):
    for file in files:
        if file.endswith(".sh") or file.endswith(".ps1"):
            file_path = os.path.join(root, file)
            try:
                with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read()
                if "#{ENVIRONMENT}#" in content:
                    updated = content.replace("#{ENVIRONMENT}#", resolved_env)
                    with open(file_path, "w", encoding="utf-8") as f:
                        f.write(updated)
                    print(f"INFO: Replaced environment placeholder in: {file}")
            except Exception as e:
                pass
' "$BASE_DIR" "$ENVIRONMENT"

# =====================================================================
# Step 6: Service Account Provisioning & Security Hardening
# =====================================================================
echo ""
echo -e "\e[32m[STEP 6] Provisioning Service Account & Hardening Security\e[0m"
echo -e "\e[90mExecuting New-LocalAdminAccount script to create 'svc_immortalmgmt' and lock down repository...\e[0m"

ACCOUNT_SCRIPT="$BASE_DIR/Scripts/Linux/30 - New-LocalAdminAccount.sh"
if [ -f "$ACCOUNT_SCRIPT" ]; then
    chmod +x "$ACCOUNT_SCRIPT"
    if [ "$EUID" -ne 0 ]; then
        echo -e "\e[33mWarning: This script must be run as root (sudo) to create local accounts. Prompting for sudo...\e[0m"
        sudo "$ACCOUNT_SCRIPT"
    else
        "$ACCOUNT_SCRIPT"
    fi
    echo -e "\e[32mService account created and repository security hardened successfully!\e[0m"
else
    write_log "Warning: 30 - New-LocalAdminAccount.sh not found." "WARNING"
fi

echo ""
echo -e "\e[36m================================================================="
echo -e "      INSTALLATION AND INITIAL CONFIGURATION COMPLETE!          "
echo -e "      Base Directory: $BASE_DIR"
echo -e "      Active Environment: $ENVIRONMENT"
echo -e "=================================================================\e[0m"
echo ""

write_log "Guided Install completed." "INFO"
