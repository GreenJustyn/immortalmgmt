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

write_log "Initializing Install script execution." "INFO"

# Load Global Config for Email (if exists, it might not exist on fresh clone)
if [ ! -f "$GLOBAL_FILE" ]; then
    write_log "Global configuration file not found at $GLOBAL_FILE. Creating a default one." "WARNING"
    mkdir -p "$(dirname "$GLOBAL_FILE")"
    echo '{"EmailTo": "", "EmailFrom": "", "EmailAppPassword": ""}' > "$GLOBAL_FILE"
fi

# Dependency Check
write_log "Performing dependency checks..." "INFO"
if ! command -v python3 &> /dev/null; then
    write_log "python3 is missing. Please install it." "CRITICAL"
    exit 1
fi

# Identify Hostname
HOSTNAME=$(hostname)
write_log "Identified local hostname: $HOSTNAME" "INFO"

# Create Hosts folder if it doesn't exist
HOSTS_DIR="$BASE_DIR/Variables/Hosts"
mkdir -p "$HOSTS_DIR"

# Create Host specific folder
HOST_DIR="$HOSTS_DIR/$HOSTNAME"
if [ ! -d "$HOST_DIR" ]; then
    mkdir -p "$HOST_DIR"
    write_log "Created Host directory: $HOST_DIR" "INFO"
else
    write_log "Host directory already exists: $HOST_DIR" "INFO"
fi

# Copy files from DefaultHost
DEFAULT_HOST_DIR="$HOSTS_DIR/DefaultHost"
if [ -d "$DEFAULT_HOST_DIR" ]; then
    for file in "$DEFAULT_HOST_DIR"/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            dest_file="$HOST_DIR/$filename"
            if [ ! -f "$dest_file" ]; then
                cp "$file" "$dest_file"
                write_log "Copied $filename to $HOST_DIR" "INFO"
            else
                write_log "$filename already exists in $HOST_DIR. Skipping copy." "INFO"
            fi
        fi
    done
else
    write_log "DefaultHost directory not found at $DEFAULT_HOST_DIR. Cannot copy default files." "WARNING"
fi

# Populate .keep if needed
KEEP_FILE="$HOST_DIR/.keep"
if [ ! -f "$KEEP_FILE" ]; then
    echo "This folder is for host $HOSTNAME variables." > "$KEEP_FILE"
    write_log "Created .keep file in $HOST_DIR" "INFO"
fi

# Gather System Info and create _Host.json using Python
write_log "Gathering system information for $HOSTNAME..." "INFO"

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
        # Get IPs
        ip_out = subprocess.check_output(["hostname", "-I"]).decode()
        ip_addresses = [ip for ip in ip_out.split() if not ip.startswith("127.")]
        
        # Get MACs
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
        
    print(f"INFO: Created thorough set of variables in {host_vars_file}")
except Exception as e:
    print(f"ERROR: Failed to gather system info: {e}")
    sys.exit(1)
' "$HOST_DIR" "$HOSTNAME"

if [ $? -ne 0 ]; then
    write_log "Failed to create _Host.json." "ERROR"
fi

# Update .gitignore
GITIGNORE_FILE="$BASE_DIR/.gitignore"
IGNORE_ENTRY="Variables/Hosts/$HOSTNAME/"

if [ -f "$GITIGNORE_FILE" ]; then
    if ! grep -q "$IGNORE_ENTRY" "$GITIGNORE_FILE"; then
        echo "$IGNORE_ENTRY" >> "$GITIGNORE_FILE"
        write_log "Added $IGNORE_ENTRY to .gitignore" "INFO"
    else
        write_log "$IGNORE_ENTRY already present in .gitignore" "INFO"
    fi
else
    echo "$IGNORE_ENTRY" > "$GITIGNORE_FILE"
    write_log "Created .gitignore and added $IGNORE_ENTRY" "INFO"
fi

write_log "Install script execution completed." "INFO"
