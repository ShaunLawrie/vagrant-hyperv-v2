#Requires -Modules VagrantMessages

param(
    [Parameter(Mandatory=$true)]
    [string]$VmId
)

$ErrorActionPreference = "Stop"

try {
    $resultHash = @{}
    $vm = Hyper-V\Get-VM -Id $VmId
    $networks = Hyper-V\Get-VMNetworkAdapter -VM $vm | Where-Object { $_.SwitchName -ne "Default Switch" }
    # virtualbox NIC numbering starts at 1 so this is emulating it and we don't set static IPs on the default switch
    for($i = 0; $i -lt $networks.Count; $i++) {
        $mac_address = $networks[$i].MacAddress
        $resultHash["$($i + 1)"] = "$mac_address"
    }

    $result = ConvertTo-Json $resultHash
    Write-OutputMessage $result
} catch {
    Write-ErrorMessage "Unexpected error while fetching MAC addresses: ${PSItem}"
    exit 1
}

<#
def read_mac_addresses
    macs = {}
    info = execute("showvminfo", @uuid, "--machinereadable", retryable: true)
    info.split("\n").each do |line|
    if matcher = /^macaddress(\d+)="(.+?)"$/.match(line)
        adapter = matcher[1].to_i
        mac = matcher[2].to_s
        macs[adapter] = mac
    end
    end
    macs
end
#>