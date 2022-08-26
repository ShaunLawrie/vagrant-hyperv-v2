#Requires -Modules VagrantMessages, VagrantNetwork

$networkConfigs = @(Get-VagrantHostNetworkConfiguration -ExcludeVagrantNetworks)
Write-OutputMessage $(ConvertTo-JSON $networkConfigs)
