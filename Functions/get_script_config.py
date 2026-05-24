#!/usr/bin/env python3
import sys
import os
import json
import socket

def main():
    if len(sys.argv) < 2:
        print("Usage: get_script_config.py <ScriptName>")
        sys.exit(1)

    script_name = sys.argv[1]
    
    # Locate paths relative to this script
    functions_dir = os.path.dirname(os.path.abspath(__file__))
    base_dir = os.path.dirname(functions_dir)
    variables_dir = os.path.join(base_dir, "Variables")

    # 1. Identity Resolution
    hostname = socket.gethostname()
    os_name = "Linux"
    org_name = "DefaultOrg"
    env_name = "DefaultEnv"

    identity_file = os.path.join(variables_dir, "_NodeIdentity.json")
    if os.path.exists(identity_file):
        try:
            with open(identity_file, "r") as f:
                identity = json.load(f)
                org_name = identity.get("Org", org_name)
                env_name = identity.get("Env", env_name)
        except Exception:
            pass

    config_hash = {}

    def merge_json(path):
        if os.path.exists(path):
            try:
                with open(path, "r") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        for k, v in data.items():
                            config_hash[k] = v
            except Exception:
                pass

    # Layer 1: Global
    merge_json(os.path.join(variables_dir, "_Global.json"))

    # Layer 1.5: Legacy/Default (Root of Variables)
    merge_json(os.path.join(variables_dir, f"{script_name}.json"))

    # Layer 2: Org
    org_dir = os.path.join(variables_dir, "Orgs", org_name)
    merge_json(os.path.join(org_dir, "_Org.json"))
    merge_json(os.path.join(org_dir, f"{script_name}.json"))

    # Layer 3: Env
    env_dir = os.path.join(variables_dir, "Envs", env_name)
    merge_json(os.path.join(env_dir, "_Env.json"))
    merge_json(os.path.join(env_dir, f"{script_name}.json"))

    # Layer 4: OS
    os_dir = os.path.join(variables_dir, "OS", os_name)
    merge_json(os.path.join(os_dir, f"_{os_name}.json"))
    merge_json(os.path.join(os_dir, f"{script_name}.json"))

    # Layer 5: Host
    host_dir = os.path.join(variables_dir, "Hosts", hostname)
    merge_json(os.path.join(host_dir, "_Host.json"))
    merge_json(os.path.join(host_dir, f"{script_name}.json"))

    # Print unified config directly to stdout
    print(json.dumps(config_hash, indent=4))

if __name__ == "__main__":
    main()
