#Requires -Modules VagrantMessages, VagrantNetwork

$Switches = @(Get-VagrantSwitches -Type "Managed" `
    | Select-Object Name,SwitchType,NetAdapterInterfaceDescription,Id)
Write-OutputMessage $(ConvertTo-JSON $Switches)
