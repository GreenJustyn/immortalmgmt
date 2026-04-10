Param(
    [Parameter(Mandatory=$true)][string]$ScriptName
)

$FunctionsDir = $PSScriptRoot
if ($FunctionsDir -match "Functions$") {
    $BaseDir = Split-Path $FunctionsDir -Parent
} else {
    # Fallback if someone moved the function
    $BaseDir = $FunctionsDir
}
$VariablesDir = Join-Path $BaseDir "Variables"

# 1. Identity Resolution
$HostName = $env:COMPUTERNAME
$OSName = if ($IsWindows -or $env:OS -match "Windows") { "Windows" } else { "Linux" }

$OrgName = "DefaultOrg"
$EnvName = "DefaultEnv"

$IdentityFile = Join-Path $VariablesDir "_NodeIdentity.json"
if (Test-Path $IdentityFile) {
    try {
        $Identity = Get-Content -Path $IdentityFile | ConvertFrom-Json
        if ($Identity.Org) { $OrgName = $Identity.Org }
        if ($Identity.Env) { $EnvName = $Identity.Env }
    } catch {
        # Fallback if JSON is invalid
    }
}

$ConfigHash = @{}

# Helper function to merge JSON into hash
function Merge-Json {
    Param([string]$Path)
    if (Test-Path $Path) {
        try {
            $Json = Get-Content -Path $Path | ConvertFrom-Json
            foreach ($prop in $Json.psobject.Properties) {
                $ConfigHash[$prop.Name] = $prop.Value
            }
        } catch {
            # Log or handle invalid JSON if needed, for now just skip
        }
    }
}

# Layer 1: Global
Merge-Json (Join-Path $VariablesDir "_Global.json")

# Layer 1.5: Legacy/Default (Root of Variables)
Merge-Json (Join-Path $VariablesDir "$ScriptName.json")

# Layer 2: Org
$OrgDir = Join-Path (Join-Path $VariablesDir "Orgs") $OrgName
Merge-Json (Join-Path $OrgDir "_Org.json")
Merge-Json (Join-Path $OrgDir "$ScriptName.json")

# Layer 3: Env
$EnvDir = Join-Path (Join-Path $VariablesDir "Envs") $EnvName
Merge-Json (Join-Path $EnvDir "_Env.json")
Merge-Json (Join-Path $EnvDir "$ScriptName.json")

# Layer 4: OS
$OSDir = Join-Path (Join-Path $VariablesDir "OS") $OSName
Merge-Json (Join-Path $OSDir "_OS.json")
Merge-Json (Join-Path $OSDir "$ScriptName.json")

# Layer 5: Host
$HostDir = Join-Path (Join-Path $VariablesDir "Hosts") $HostName
Merge-Json (Join-Path $HostDir "_Host.json")
Merge-Json (Join-Path $HostDir "$ScriptName.json")

return [PSCustomObject]$ConfigHash
