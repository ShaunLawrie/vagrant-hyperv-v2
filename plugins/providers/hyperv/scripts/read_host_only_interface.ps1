#Requires -Modules VagrantMessages, VagrantNetwork

# Only one host-only switch at the moment
$hostOnlySwitch = Get-VagrantSwitches -Type "Managed" `
    | Where-Object { $_.SwitchType -eq "internal" }

$hostOnlyAdapter = Get-NetAdapter -Name "*$($hostOnlySwitch.Name)*"
$hostOnlyIpAddresses = $hostOnlyAdapter | Get-NetIPAddress
$ipv4 = $hostOnlyIpAddresses | Where-Object { $_.AddressFamily -eq "IPv4" } | Select-Object -First 1
$ipv6 = $hostOnlyIpAddresses | Where-Object { $_.AddressFamily -eq "IPv6" } | Select-Object -First 1

$interface = @{
    Name = $hostOnlyAdapter.InterfaceDescription
    IP = $ipv4.IPAddress
    Netmask = (ConvertTo-IPv4MaskString $ipv4.PrefixLength)
    IPv6 = $ipv6.IPAddress
    IPv6Prefix = $ipv6.PrefixLength
    Status = $hostOnlyAdapter.Status
}

Write-OutputMessage $(ConvertTo-JSON $interface)

<#
VirtualBox\VBoxManage.exe" list hostonlyifs
Name:            VirtualBox Host-Only Ethernet Adapter #2
GUID:            49e7422d-a7de-490b-90c0-e896380165c4
DHCP:            Disabled
IPAddress:       10.20.30.1
NetworkMask:     255.255.255.0
IPV6Address:     fe80::f817:64c:8a27:3cbf
IPV6NetworkMaskPrefixLength: 64
HardwareAddress: 0a:00:27:00:00:0e
MediumType:      Ethernet
Wireless:        No
Status:          Up
VBoxNetworkName: HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter #2

Name:            VirtualBox Host-Only Ethernet Adapter
GUID:            8b96dc0e-824b-4b9e-a7b6-fdb61d32acc9
DHCP:            Disabled
IPAddress:       192.168.56.1
NetworkMask:     255.255.255.0
IPV6Address:     fe80::6995:7c22:d955:524e
IPV6NetworkMaskPrefixLength: 64
HardwareAddress: 0a:00:27:00:00:18
MediumType:      Ethernet
Wireless:        No
Status:          Up
VBoxNetworkName: HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter

def read_host_only_interfaces
    execute("list", "hostonlyifs", retryable: true).split("\n\n").collect do |block|
    info = {}

    block.split("\n").each do |line|
        if line =~ /^Name:\s+(.+?)$/
        info[:name] = $1.to_s
        elsif line =~ /^IPAddress:\s+(.+?)$/
        info[:ip] = $1.to_s
        elsif line =~ /^NetworkMask:\s+(.+?)$/
        info[:netmask] = $1.to_s
        elsif line =~ /^IPV6Address:\s+(.+?)$/
        info[:ipv6] = $1.to_s.strip
        elsif line =~ /^IPV6NetworkMaskPrefixLength:\s+(.+?)$/
        info[:ipv6_prefix] = $1.to_s.strip
        elsif line =~ /^Status:\s+(.+?)$/
        info[:status] = $1.to_s
        end
    end

    info
    end
end
#>