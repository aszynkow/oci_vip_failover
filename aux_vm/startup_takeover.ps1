[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'vip_config.json'),
  [string]$AuthMode,
  [string]$OciConfigFile,
  [string]$Profile,
  [string]$Region,
  [string]$VnicId,
  [int]$WaitSecs,
  [int]$PollSecs = 2,
  [switch]$DryRun,
  [switch]$NoInstallOciCli
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'oci_cli_common.ps1')

function Get-TargetIdentity {
  param(
    [object]$Config,
    [string]$CliVnicId
  )

  if (Test-VipValue -Value $CliVnicId) {
    return [ordered]@{
      vnic_id = $CliVnicId
      source = 'cli'
    }
  }

  $ConfigVnic = Get-ConfigValue -Config $Config -Keys @('target_vnic_id', 'vnic_id')
  if (Test-VipValue -Value $ConfigVnic) {
    return [ordered]@{
      vnic_id = $ConfigVnic
      source = 'config'
    }
  }

  throw 'Target VNIC ID is required. Supply -VnicId or set target_vnic_id/vnic_id in vip_config.json.'
}

function Get-CurrentAssignments {
  param(
    [object[]]$Vips,
    [string[]]$BaseArgs
  )

  $Assignments = [ordered]@{}
  foreach ($Vip in $Vips) {
    $PrivateIp = Get-PrivateIpById -PrivateIpId $Vip.private_ip_ocid -BaseArgs $BaseArgs
    $Assignments[$Vip.ip] = [ordered]@{
      private_ip_ocid = $Vip.private_ip_ocid
      vnic_id = [string](Get-JsonProperty -Object $PrivateIp -Names @('vnic-id', 'vnic_id', 'vnicId'))
    }
  }
  return $Assignments
}

function Wait-ForAssignments {
  param(
    [object[]]$Vips,
    [string]$TargetVnicId,
    [string[]]$BaseArgs,
    [int]$TimeoutSecs,
    [int]$PollSeconds
  )

  $Deadline = (Get-Date).AddSeconds($TimeoutSecs)
  do {
    $Assignments = Get-CurrentAssignments -Vips $Vips -BaseArgs $BaseArgs
    $AllMoved = $true
    foreach ($Vip in $Vips) {
      if ($Assignments[$Vip.ip]['vnic_id'] -ne $TargetVnicId) {
        $AllMoved = $false
        break
      }
    }
    if ($AllMoved) { return $Assignments }
    Start-Sleep -Seconds $PollSeconds
  } while ((Get-Date) -lt $Deadline)

  throw "VIPs did not all move to VNIC $TargetVnicId within $TimeoutSecs seconds."
}

function Move-Vips {
  param(
    [object[]]$Vips,
    [string]$TargetVnicId,
    [string[]]$BaseArgs,
    [switch]$DryRun,
    [int]$TimeoutSecs,
    [int]$PollSeconds
  )

  $Actions = New-Object System.Collections.Generic.List[object]
  $Moved = $false

  foreach ($Vip in $Vips) {
    $PrivateIp = Get-PrivateIpById -PrivateIpId $Vip.private_ip_ocid -BaseArgs $BaseArgs
    $CurrentVnicId = [string](Get-JsonProperty -Object $PrivateIp -Names @('vnic-id', 'vnic_id', 'vnicId'))
    if ($CurrentVnicId -eq $TargetVnicId) {
      $ActionName = 'already_on_target'
    } else {
      $ActionName = 'move'
    }

    if ($CurrentVnicId -ne $TargetVnicId) {
      if ($DryRun) {
        $ActionName = 'would_move'
      } else {
        Invoke-OciJson -Arguments (@('network', 'vnic', 'assign-private-ip', '--vnic-id', $TargetVnicId, '--ip-address', $Vip.ip, '--unassign-if-already-assigned', '--output', 'json') + $BaseArgs) | Out-Null
        $Moved = $true
      }
    }

    [void]$Actions.Add([ordered]@{
      ip = $Vip.ip
      private_ip_ocid = $Vip.private_ip_ocid
      from_vnic_id = $CurrentVnicId
      to_vnic_id = $TargetVnicId
      action = $ActionName
    })
  }

  if ($DryRun) {
    $Assignments = Get-CurrentAssignments -Vips $Vips -BaseArgs $BaseArgs
  } elseif ($Moved) {
    $Assignments = Wait-ForAssignments -Vips $Vips -TargetVnicId $TargetVnicId -BaseArgs $BaseArgs -TimeoutSecs $TimeoutSecs -PollSeconds $PollSeconds
  } else {
    $Assignments = Get-CurrentAssignments -Vips $Vips -BaseArgs $BaseArgs
  }

  return [ordered]@{
    actions = $Actions.ToArray()
    assignments = $Assignments
  }
}

$Config = Read-VipConfig -Path $ConfigPath
$Vips = @(Get-ManagedVips -Config $Config)
$Target = Get-TargetIdentity -Config $Config -CliVnicId $VnicId
$TargetVnicId = [string](Get-VipProperty -Object $Target -Name 'vnic_id')
if (-not $TargetVnicId) { throw 'Target VNIC ID is empty.' }

$AuthDefault = [string](Get-AgentValue -Config $Config -Key 'auth_mode' -Default 'instance_principal')
$AuthMode = Normalize-VipAuthMode -Value (Get-ConfigValue -CliValue $AuthMode -Config $Config -Keys @('auth_mode') -Default $AuthDefault) -Default 'instance_principal'
$OciConfigFile = Get-ConfigValue -CliValue $OciConfigFile -Config $Config -Keys @('oci_config_file', 'config_file')
$Profile = Get-ConfigValue -CliValue $Profile -Config $Config -Keys @('profile') -Default 'DEFAULT'
$Region = Get-ConfigValue -CliValue $Region -Config $Config -Keys @('region')
if (-not $WaitSecs -or $WaitSecs -le 0) { $WaitSecs = [int](Get-AgentValue -Config $Config -Key 'oci_wait_secs' -Default 60) }
if (-not $PollSecs -or $PollSecs -le 0) { $PollSecs = 2 }

Ensure-OciCli -NoInstall:$NoInstallOciCli | Out-Null
$BaseArgs = Get-OciBaseArgs -AuthMode $AuthMode -ConfigFile $OciConfigFile -Profile $Profile -Region $Region
$MoveResult = Move-Vips -Vips $Vips -TargetVnicId $TargetVnicId -BaseArgs $BaseArgs -DryRun:$DryRun -TimeoutSecs $WaitSecs -PollSeconds $PollSecs

$VipIpsList = New-Object System.Collections.Generic.List[string]
foreach ($Vip in $Vips) { [void]$VipIpsList.Add([string]$Vip.ip) }
$VipIps = $VipIpsList.ToArray()
$LocalBindCommand = 'C:\vip-agent\repo\windows_vms\add_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json'

if ($DryRun) {
  $ResultMode = 'DRY_RUN_NO_CHANGES'
} else {
  $ResultMode = 'OCI_TAKEOVER'
}

Write-VipJsonResult -Result ([ordered]@{
  mode = $ResultMode
  auth_mode = $AuthMode
  target = $Target
  oci_actions = $MoveResult.actions
  oci_assignments = $MoveResult.assignments
  next_step = [ordered]@{
    run_on_target_vm = $LocalBindCommand
    vip_ips = $VipIps
  }
})

