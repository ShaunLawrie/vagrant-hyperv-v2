#Requires -Modules VagrantMessages, VagrantNetwork

$networkConfigs = @(Get-VagrantHostNetworkConfiguration)
Write-OutputMessage $(ConvertTo-JSON $networkConfigs)
