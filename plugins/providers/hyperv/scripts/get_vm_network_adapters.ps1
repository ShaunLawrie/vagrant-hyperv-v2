#Requires -Modules VagrantMessages, VagrantNetwork

param(
    [Parameter(Mandatory=$true)]
    [string]$VmId
)

$switches = Get-VagrantSwitches -Type "All"

# virtualbox NIC numbering starts at 1 so this is emulating it
$number = 1
$nics = @()
Get-VM -Id $VmId | Get-VMNetworkAdapter | Foreach-Object {
    $switchId = $_.SwitchId
    $adapterSwitch = $switches | Where-Object { $_.Id -eq $switchId }
    $hostAdapter = Get-NetAdapter -Name "*$($adapterSwitch.Name)*"
    if($hostAdapter) {
        $hostAdapter = $hostAdapter.Name
    } else {
        $hostAdapter = ""
    }

    # Map the Hyper-V switch types to the VirtualBox equivalents
    # hostonly, nat, internal, bridged, intnet
    $adapterNumber = $number++
    $type = $null
    switch ($adapterSwitch.SwitchType) {
        "nat" { $type = "nat" }
        "internal" { $type = "hostonly" }
        "private" { $type = "intnet" }
        "external" { $type = "bridged" }
        default {
            Write-ErrorMessage "Invalid switch type found on VM '$($adapterSwitch.SwitchType)', expected one of [nat, internal, private, external]"
        }
    }
    $nics += @{
        Number = $adapterNumber
        Type = $type
        Network = $hostAdapter
    }
}

Write-OutputMessage $(ConvertTo-JSON $nics)

<#
Example output:
[
    {
        "Network":  "vEthernet (Default Switch)",
        "Number":  1,
        "Type":  "nat"
    },
    {
        "Network":  "vEthernet (Vagrant Host Only)",
        "Number":  2,
        "Type":  "hostonly"
    }
]
#>

<#
def read_network_interfaces
    nics = {}
    info = execute("showvminfo", @uuid, "--machinereadable", retryable: true)
    adapters.each do ||
    if line =~ /^nic(\d+)="(.+?)"$/
        adapter = $1.to_i
        type    = $2.to_sym

        nics[adapter] ||= {}
        nics[adapter][:type] = type
    elsif line =~ /^hostonlyadapter(\d+)="(.+?)"$/
        adapter = $1.to_i
        network = $2.to_s

        nics[adapter] ||= {}
        nics[adapter][:hostonly] = network
    elsif line =~ /^bridgeadapter(\d+)="(.+?)"$/
        adapter = $1.to_i
        network = $2.to_s

        nics[adapter] ||= {}
        nics[adapter][:bridge] = network
    end
    end

    nics
end
#>