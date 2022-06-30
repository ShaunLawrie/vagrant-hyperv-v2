#Requires -Modules VagrantNetwork

$ErrorActionPreference = "Stop"

try {
    Install-MissingVagrantSwitches
} catch {
    Write-ErrorMessage "Failed to install missing hyper-v switches for vagrant: ${PSItem}"
    exit 1
}