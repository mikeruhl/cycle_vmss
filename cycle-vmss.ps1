<#
.SYNOPSIS
    Reimages VMSS machines one-by-one based on health
.DESCRIPTION
    Using the health and status of an Azure VMSS, this script will ensure a healthy and coordinated recycle and reimage of all servers in a scale set.
.EXAMPLE
    PS C:\\> cycle-vmss.ps1 -ResourceGroupName ba-na-na-rg -ScaleSetName orangevmss -TimeoutMinutes 45
    This will perform a reimage on scale set orangevmss with a per-vm timeout of 45 minutes
.INPUTS
    ResourceGroupName, ScaleSetName
.OUTPUTS
    None
.NOTES
    More information on author and script can be found at https://github.com/mikeruhl/cycle_vmss
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)]
    [string]$ScaleSetName,
    [int]$TimeoutMinutes = 30,
    [switch]$IgnoreInitialHealth,
    [switch]$IgnoreAvailability
)

function Get-VmStatus {
    param (
        $state
    )
    $isRunning = 0;
    foreach ($s in $state.statuses) {
        if ($s.code -eq 'ProvisioningState/succeeded') {
            $isRunning += 1;
        }
        elseif ($s.code -eq 'PowerState/running') {
            $isRunning += 2;
        }
    }
    $health = $state.vmHealth.status.code
    if ($health -eq 'HealthState/healthy') {
        $isRunning += 4;
    }
    return $isRunning;
}

function Get-InitialHealth {
    param(
        [Parameter(Mandatory = $true)]
        $instances
    )
    $totalHealth = 0;
    foreach ($i in $instances) {
        $state = az vmss get-instance-view -g $ResourceGroupName -n $ScaleSetName --instance-id $i.instanceId | ConvertFrom-Json
        $stateScore = Get-VmStatus -state $state
        Write-Host "$(Get-Date) [$($i.instanceId)] Health Score: $($stateScore)";
        $totalHealth += $stateScore;
    }
    return $totalHealth;
}

function Scale-Up {
   param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)]
    [string]$ScaleSetName
   ) 
   az vmss scale --new-capacity 2 -n $ScaleSetName -g $ResourceGroupName --no-wait
   $allHealthy = $false;
   $scaleStarted = $false;
   while ($false -eq $allHealthy) {
    if($false -eq $scaleStarted) {
        $newCount = az vmss list-instances -g $ResourceGroupName -n $ScaleSetName | ConvertFrom-Json;
        if($newCount -eq 2) {
            Write-Output "Scale up has started in Azure."
            $scaleStarted = $true
        }
        Start-Sleep -s 5
    } else {
        $scaling = az vmss list-instances -g $ResourceGroupName -n $ScaleSetName | ConvertFrom-Json;
        $scores = Get-InitialHealth -instances $scaling;
        if($scores -ge $scaling.Length * 7) {
            $allHealthy = $true;
            Write-Output "Scaling up complete."
        } else{
            Write-Output "Still scaling up."
            Start-Sleep -s 15
        }
    }   
   }
}

### Check for Initial Health of cluster
if ($false -eq $IgnoreInitialHealth) {
    Write-Host "$(Get-Date) Preparing to cycle instances.  Getting health score of all instances to determine scale set health."
    $instances = az vmss list-instances -g $ResourceGroupName -n $ScaleSetName | ConvertFrom-Json
    $initialHealth = Get-InitialHealth -instances $instances;
    if ($initialHealth -lt ($instances.Length * 7)) {
        Write-Error "$(Get-Date) Instance found to be unhealthy, cannot continue with cycle until instance made healthy";
        exit 1;
    }
}
else {
    Write-Host "$(Get-Date) Skipping initial health check."
}

### Scale up if only 1 server
if($instances.Length -eq 1 -and $false -eq $IgnoreAvailability) {
    Write-Host "$(Get-Date) Only one instance found.  Scaling up to two for availability";
   Scale-Up -ResourceGroupName $ResourceGroupName -ScaleSetName $ScaleSetName
}

Write-Host "$(Get-Date) Beginning Server Cycle."
foreach ($i in $instances) {
    $timeOut = (Get-Date).AddMinutes($TimeoutMinutes);
    $state = az vmss get-instance-view -g $ResourceGroupName -n $ScaleSetName --instance-id $i.instanceId | ConvertFrom-Json
    $stateScore = Get-VmStatus -state $state
    if ($stateScore -lt 7) {
        Write-Error "$(Get-Date) Instance [$($i.instanceId)] found to be unhealthy, cannot continue with cycle until instance made healthy";
        exit 1;
    }
    Write-Output "$(Get-Date) Instance [$($i.instanceId)] Beginning reimage."
    # reimage
    az vmss reimage --instance-id $i.instanceId -n $ScaleSetName -g $ResourceGroupName --no-wait
    $processStarted = $false;
    $processOver = $false;
    while ($false -eq $processStarted -or $false -eq $processOver) {
        $upgradeState = az vmss get-instance-view -g $ResourceGroupName -n $ScaleSetName --instance-id $i.instanceId | ConvertFrom-Json;
        $upgradeScore = Get-VmStatus -state $upgradeState
        if ($processStarted -eq $false) {
            if ($upgradeScore -lt 7) {
                $processStarted = $true;
                Write-Output "$(Get-Date) Instance [$($i.instanceId)] Reimage has started."
            }
        }
        elseif ($upgradeScore -ge 7) {
            $processOver = $true
            Write-Output "$(Get-Date) Instance [$($i.instanceId)] Reimage has completed, moving on."
        }
        else {
            if ($timeOut -lt (Get-Date)) {
                Write-Error "$(Get-Date) Instance [$($i.instanceId)] Timeout Occurred.  Please complete manually."
                exit 1;
            }
            Write-Output "$(Get-Date) Instance [$($i.instanceId)] Reimage in progress. (Score: $($upgradeScore))"
            Start-Sleep -s 15
        }
    }
    Write-Output "$(Get-Date) Reimage completed successfully";
}
