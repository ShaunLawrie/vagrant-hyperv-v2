#Requires -Modules VagrantMessages, VagrantNetwork

$ErrorActionPreference = "Stop"

try {
    Install-VagrantManagedSwitches
} catch {
    Write-ErrorMessage "Failed to install missing hyper-v switches for vagrant: ${PSItem}"
    exit 1
}