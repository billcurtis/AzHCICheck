$VMswitchName = "vSwitch"
$NetworkAdapterNames = @('PCIe Slot 1 Port 1', 'PCIe Slot 2 Port 2')

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"


$VMcred = Get-Credential -Message 'Enter the Credential that will be used to connect to the Virtual Machines' 

# Sets the Hypervisor to Classic Mode
Write-Verbose "Setting Scheduler Type"
bcdedit /set hypervisorschedulertype classic

# Sets High Performance Mode
Write-Verbose "Setting High Performance"
powercfg.exe -SETACTIVE 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# Remove VM Switch vSwitch
Write-Verbose "Removing VM Switch"
Get-VM | Get-VMNetworkAdapter | Disconnect-VMNetworkAdapter
Get-VMSwitch | Remove-VMSwitch -Force

Write-Verbose "Removing LBFO"
# Remove NetLBFO
Get-NetLbfoTeam | Remove-NetLbfoTeam

Write-Verbose "Adding VM Switch"
# Add VM Switch vSwitch with correct weight
New-VMSwitch -NetAdapterName $NetworkAdapterNames -AllowManagementOS $true -MinimumBandwidthMode Weight -Name $VMswitchName -EnableEmbeddedTeaming $True 

Write-Verbose "Reconnecting Network Adapters"
# Add new VMSwitch to all of the new VMs
Get-VM | Get-VMNetworkAdapter | Connect-VMNetworkAdapter -SwitchName $VMswitchName

Write-Verbose "Setting Bandwidth Weight on VM Network Adapters"
# Set bandwidth weight on VMs
Get-VM | Set-VMNetworkAdapter -MinimumBandwidthWeight 40

# Fin

