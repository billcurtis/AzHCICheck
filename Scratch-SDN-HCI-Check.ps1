<#

.SYNOPSIS

This script was created by the Microsoft SDN Blackbelt Team. It will provide numerous checks that are considered and monitored 
as a best practices for Edge AzStackHCI clusters.  

This provides reporting *ONLY*. No changes will be made when running this script.
This needs to be ran on each Hyper-V node.  

The credential being asked for must have local administrative privilages on all VMs within the host.

#>

# Get Credential for Virtual Machine access.
$VMcred = Get-Credential -Message 'Enter the Credential that will be used to connect to the Virtual Machines' 
$MTUSize = 9014
$VMWeight = 40


# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

#region functions

function Get-vmSwitches {

    Write-Verbose "Getting External Switches"
    $vmSwitches = Get-VMSwitch | Where-Object { $_.SwitchType -eq "External" }

    If (!$vmSwitches) {

        Write-Error "No External VM Switches were found."


    }

    return $VMSwitches

}
function Get-jumboFrames {

    param ($vmSwitches, $MTUSize)

    $nics = $vmSwitches.NetAdapterInterfaceDescription
    $selJumbo = @()

    foreach ($nic in $nics) {

        Write-Verbose "Getting Jumbo Frame data for NIC: $nic"

        $params = @{

            InterfaceDescription = $nic
            RegistryKeyword      = '*JumboPacket'

        }

        $JumboPacketSize = (Get-NetAdapterAdvancedProperty @params).RegistryValue

        if ($JumboPacketSize -ne $MTUSize) {

            $selJumbo += [pscustomobject]@{

                Adapter  = $nic 
                MTUValue = $JumboPacketSize

            }

            Return $selJumbo

        }


    }



}
function Get-vmNICData {

    param ($MTUSize, $VMcred)

    $report = @()

    $runningVMs = Get-VM | Where-Object { $_.State -eq "Running" }

    foreach ($runningVM in $runningVMs) {

        Write-Verbose "Getting NIC information from VM: $($runningVM.Name)"

        $nicReport = Invoke-Command -VMId $runningVM.VMId -ArgumentList $MTUSize -Credential $VMcred -ScriptBlock {

            $vmNICdata = @()
            $MTUSize = $using:MTUSize

            $nmMTU = Get-NetAdapterAdvancedProperty -RegistryKeyword '*JumboPacket' | Where-Object { $_.RegistryValue -ne $MTUSize }
            $nmRSS = Get-NetAdapterRss | Where-Object { !$_.Enabled }

            if ($nmMTU) {

                foreach ($nmMTUdata in $nmMTU) {

                    $vmNICdata += [pscustomobject]@{

                        vNICName     = $nmMTUdata.Name
                        Area         = "Jumbo Frames Value"
                        CurrentValue = $nmMTUdata.RegistryValue

                    }

                }

            }

            if ($nmRSS) {

                foreach ($nmRSSdata in $nmRSS) {

                    $vmNICdata += [pscustomobject]@{

                        vNICName     = $nmRSSdata.Name
                        Area         = "RSS Setting"
                        CurrentValue = $nmRSSdata.Enabled

                    }

                }

            }

            return $vmNICdata

        }

        $report += $nicReport


    }


    $report


}
function Get-vmNUMAdata {

    Write-Verbose "Checking all VMs to ensure that NUMA Configuration is correct for the hardware."

    [int]$coreCount = (Get-WmiObject -Class Win32_Processor).NumberOfLogicalProcessors[0]

    $vmNumaData = Get-VM | Get-VMProcessor | Where-Object { $_.MaximumCountPerNumaNode -ne $coreCount }

    if (!$vmNumaData) { Write-Verbose "PASSED: NUMA Configuration Check Passed" }

}
function Get-vmBandwidthWeight {

    param ($VMWeight)

    $badWeight = @()

    $vNICIDs = Get-VM | Get-VMNetworkAdapter | Select-Object VMName, Id
    foreach ($vNic in $vNICIDs) {

        Write-Verbose "Getting VM Bandwidth Weight for $vNic.Id "

        $length = $vNic.Id.length

        $weight = (Get-WmiObject -Namespace root/virtualization/v2 `
                -class Msvm_EthernetSwitchPortBandwidthSettingData | `
                Where-Object { $_.InstanceID.length -gt $length } | `
                Where-Object { $_.InstanceID.substring(0, $length) -eq $vNic.Id }).Weight
 
        if ($weight -ne $VMWeight) {

            if (!$weight) { $weight = 0 }

            Write-Verbose "$($vNic.VMName) has an incorrect Weight value of: $weight"

            $badWeight += [pscustomobject]@{

                vNICName     = $vNic.VMName
                Area         = "Bandwidth Weight"
                CurrentValue = $weight


            }

        }

    }

    return $badWeight

}
function Get-vmCompatiblityMode { 

    Write-Verbose "Getting VM CPU Compatibility Settings"
    $vmProcs = Get-VM | Get-VMProcessor | Where-Object { $_.CompatibilityForMigrationEnabled -eq $true -or $_.CompatibilityForOlderOperatingSystemsEnabled -eq $true }
    return $vmProcs

}

function Get-powerPlan {

Write-Verbose "Getting Power Plan data locally."
  $highPerfCheck =  (Get-CimInstance -Name root\cimv2\power -Class win32_PowerPlan | Where-Object {$_.Elementname -eq "High performance"}).IsActive
  return $highPerfCheck


}

function Get-vmPowerPlan {

    $report = @()
    $runningVMs = Get-VM | Where-Object { $_.State -eq "Running" }

    foreach ($runningVM in $runningVMs) {

        Write-Verbose "Getting VM Power Plan information from VM: $($runningVM.Name)"

        $report += Invoke-Command -VMId $runningVM.VMId -ArgumentList $MTUSize -Credential $VMcred -ScriptBlock {
           
            $vmPowerdata = @()

            $highPerfCheck =  (Get-CimInstance -Name root\cimv2\power -Class win32_PowerPlan | Where-Object {$_.Elementname -eq "High performance"}).IsActive

            Write-Verbose $highPerfCheck

            if (!$highPerfCheck) {


                    $vmPowerdata += [pscustomobject]@{

                        vmName     =  $env:COMPUTERNAME
                        Area         = "High Performance Power Plan enabled?"
                        CurrentValue = 'Not Enabled'

                    }

                }

                return $vmPowerdata

            }

        }

        return $report

}

function Get-coreSchedular {

    Write-Verbose "Getting Core Scheduler Information"

    $VerbosePreference = "SilentlyContinue"
    $cpuScheduler = Get-WinEvent -FilterHashTable @{ProviderName="Microsoft-Windows-Hyper-V-Hypervisor"; ID=2} -MaxEvents 1
    $VerbosePreference = "Continue"
    if ($cpuScheduler.Message -match '0x2') {$cpuScheduler = "Classic"}
    if ($cpuScheduler.Message -match '0x3') {$cpuScheduler = "Core"}
    if ($cpuScheduler.Message -match '0x1') {$cpuScheduler = "Classic\SMT disabled"}
    

    return $cpuScheduler 

}


#endregion

#region Collect Data

# Get VM Switch data

$vmSwitches = Get-vmSwitches


# Get Jumbo Frames (Physical Host) data

$params = @{

    vmSwitches = $vmSwitches
    MTUSize    = $MTUSize

}

$jumboData = Get-jumboFrames @params

# Get VM NIC Data

$params = @{

    VMCred  = $VMcred
    MTUSize = $MTUSize

}

$vnicData = Get-vmNICData @params

$vmNUMAdata = Get-vmNUMAdata

# Get Host vNIC Data

$hostvNICData = Get-VM | Get-VMNetworkAdapter  

# Get VM Network Adapter Weight

$vmWeightReport = Get-vmBandwidthWeight -VMWeight $VMWeight

# Get CPU Compatiblity Mode
$compatMode = Get-vmCompatiblityMode

# Get Power Config
$highPerfCheck =  Get-powerPlan

#Get-VMPowerConfig 
$vmPowerConfig = Get-vmPowerPlan

#Get Schedular
$coreSceduler = Get-coreSchedular

#endregion

#region Report Data


# Report VM Compatiblity Mode Set
if ($compatMode) {

    Write-Host "ERROR: Some VM's CPUs are in 'Compatiblity Mode' and CPU performance for encoding video streams will be affected." -ForegroundColor Yellow
    Write-Output $compatMode

}
else { Write-Host "PASS: The CPU Compatiblity Mode Settings are not enabled." -ForegroundColor Green }

# Report Bad VM Numa Node
if ($vmNUMAdata) {
    Write-Host "ERROR: Some VM's Numa Node Settings appear not to be set correctly." -ForegroundColor Yellow
    Write-Output $vmNUMAdata | Format-Table -AutoSize
}
else { Write-Host "PASS: Numa Node Topology on all VMs seems fine." -ForegroundColor Green }


# Check and Report Bandwidth Mode Setting

foreach ($vmSwitch in $vmSwitches) {

    If ($vmSwitch.BandwidthReservationMode -ne "Weight") {

        Write-Host "ERROR: The VM Switch: '$($vmSwitch.Name)' should be set to a Bandwidth Reservation Mode of 'Weight' " -ForegroundColor Yellow

    }
    else {
        Write-Host "PASS: The Bandwidth Reservation Mode for the VM Switch '$($vmSwitch.Name)' is correct." -ForegroundColor Green

    }

}


# Report VM Network Adapter Weight

If ($vmWeightReport) {

    Write-Host "ERROR: Not all VMs are set to the proper Bandwidth Weight ($VMWeight). Refer to the table below for the offending VMs:" -ForegroundColor Yellow
    $vmWeightReport | Format-Table
 

}
else { Write-Host "PASS: VM Bandwidth Settings are Correct" -ForegroundColor Green }


# Report Physical Node Jumbo Frames

if ($jumboData) {

    Write-Host "ERROR: The  following Physical Adapter(s)s associated with your External Switches do not have Jumbo Frames set to $MTUSize" -ForegroundColor Yellow
    $jumboData | Format-Table 

}
else { Write-Host "PASS: Hyper-V Host Jumbo Data" -ForegroundColor Green }


# Report VM NIC Data

if ($vnicData) {

    Write-Host "ERROR: The following issues were found on the NIC configurations for the following VMs:" -ForegroundColor Yellow
    Write-Output $vnicData | Select-Object vNicName, Area, CurrentValue, PSComputerName | Format-Table -AutoSize
 
}
else { Write-Host "PASS: Hyper-V VM Nic Data" -ForegroundColor Green }


# Report Perf data
if (!$highPerfCheck) {

    Write-Host "ERROR: High Performance is not enabled for $env:COMPUTERNAME" -ForegroundColor Yellow
    
}
else { Write-Host "PASS: Power Plan is set to High Performance" -ForegroundColor Green }


# Report VM Power Plans
if ($vmPowerConfig) {

    if (!$highPerfCheck) {

        Write-Host "ERROR: Not all VMs have the correct Performance Settings:" -ForegroundColor Yellow
        $vmPowerConfig | Select-Object vmName, Area, CurrentValue |  Format-Table -AutoSize
        
    }
    else { Write-Host "PASS: All running VMs are set to High Performance" -ForegroundColor Green }



}


# Report Hyper-V Scheduler
if ($coreSceduler -ne "Classic") {

    Write-Host "ERROR: The Hyper-V Scheduler is not set to Classic. Its current value is: $coreSceduler" -ForegroundColor Yellow
    

}
else { Write-Host "PASS: The Hyper-V Scheduler is set to Classic." -ForegroundColor Green }

#endregion

 

