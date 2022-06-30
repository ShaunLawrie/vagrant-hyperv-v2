$ErrorActionPreference = "Stop"

# VM Switch Names that match the supported network types of virtualbox
$script:SwitchDefinitions = @{
    # default_network is like virtualbox's NAT network that all VMs are attached to
    default_network = @{
        Name = "Default Switch"
        Definition = {
            throw "Cannot create NAT switch 'Default Switch' this is the built-in Hyper-V NAT switch with DHCP created by enabling the Hyper-V feature in Windows. If the switch is missing try disabling and re-enabling the Hyper-V feature"
        }
    }
    # private_network provides a network between the VMs in hyper-v AND the host
    private_network = @{
        Name = "Vagrant Host Only"
        Definition = {
            New-VMSwitch -Name "Vagrant Host Only" -SwitchType "Internal" | Out-Null
        }
    }
    # internal_network provides a network between the VMs in hyper-v
    internal_network = @{
        Name = "Vagrant Internal"
        Definition = {
            New-VMSwitch -Name "Vagrant Internal" -SwitchType "Private" | Out-Null
        }
    }
}

# Check all switches exist
function Test-VagrantSwitch {
    param (
        [string] $SwitchName
    )
    Write-Verbose "Checking VMSwitch '$SwitchName' exists"
    if(Get-VMSwitch -Name $SwitchName -ErrorAction "SilentlyContinue") {
        Write-Verbose "VMSwitch '$SwitchName' exists"
        return $true
    } else {
        Write-Verbose "VMSwitch '$SwitchName' is missing"
        return $false
    }
}

# Create switches if they're missing
function Install-VagrantManagedSwitches {
    foreach($vmSwitch in $script:SwitchDefinitions.GetEnumerator()) {
        if ($vmSwitch.Key -eq "public_network") {
            Write-Verbose "Skipping public_network creation, this is done on-demand during 'vagrant up'"
            continue
        }
        if (Test-VagrantSwitch $vmSwitch.Value.Name) {
            Write-Verbose "$($vmSwitch.Key) switch '$($vmSwitch.Value.Name)' already exists"
        } else {
            Write-Verbose "Creating $($vmSwitch.Key) switch '$($vmSwitch.Value.Name)'"
            Invoke-Command $vmSwitch.Value.Definition
        }
    }
}

function Get-VagrantSwitches {
    param (
        [string] $Type
    )

    $natSwitchName = $script:SwitchDefinitions.default_network.Name

    switch ($Type) {
        "All" {
            $result = Hyper-V\Get-VMSwitch
        }
        "Managed" {
            $managedSwitchNames = $script:SwitchDefinitions.GetEnumerator() `
                | Select-Object { $_.Value.Name } `
                | Select-Object -ExpandProperty *
            
            $result = Hyper-V\Get-VMSwitch `
                | Where-Object { $managedSwitchNames -contains $_.Name }
        }
        default {
            throw "Type must be 'All' or 'Managed' for Get-VagrantSwitches"
        }
    }
    
    return $result `
        | Select-Object `
            Name,
            NetAdapterInterfaceDescription,
            Id,
            @{
                Name = "SwitchType"
                Expression = { if ($_.Name -eq $natSwitchName) { "NAT" } else { $_.SwitchType.ToString() } }
            }
}

function Get-VagrantHostNetworkConfiguration {
    $addressesInUse = Get-NetIPAddress `
        | Where-Object { $_.AddressFamily -eq "IPv4" } `
        | Select-Object IPv4Address, PrefixLength

    $ranges = $addressesInUse | ForEach-Object {
        (ConvertTo-IpRange -IPAddress $_.IPv4Address -Prefix $_.PrefixLength).IPAddressToString + "/" + $_.PrefixLength
    }
    return $ranges
}

function ConvertTo-IpRange {
    param (
        [string] $IPAddress,
        [int] $Prefix
    )
    return [IPAddress] (([IPAddress] $IPAddress).Address -band ([IPAddress] (ConvertTo-IPv4MaskString $Prefix)).Address)
}

function ConvertTo-IPv4MaskString {
    param(
      [Parameter(Mandatory = $true)]
      [ValidateRange(0, 32)]
      [Int] $MaskBits
    )
    $mask = ([Math]::Pow(2, $MaskBits) - 1) * [Math]::Pow(2, (32 - $MaskBits))
    $bytes = [BitConverter]::GetBytes([UInt32] $mask)
    $maskString = (($bytes.Count - 1)..0 | ForEach-Object { [String] $bytes[$_] }) -join "."
    return $maskString
}