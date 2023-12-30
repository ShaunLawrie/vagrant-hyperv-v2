#Requires -Modules VagrantMessages, VagrantNetwork
# This will have a SwitchType property. As far as I know the values are:
#
#   0 - Private
#   1 - Internal
#

$Switches = @(Get-VagrantSwitches -Type "All" `
    | Select-Object Name,SwitchType,NetAdapterInterfaceDescription,Id)
Write-OutputMessage $(ConvertTo-JSON $Switches)
