[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'vip_config.json'),
  [string]$AuthMode,
  [string]$OciConfigFile,
  [string]$Profile,
  [string]$Region,
  [string]$VnicId,
  [string[]]$Ip,
  [switch]$AllSecondary,
  [switch]$DryRun,
  [switch]$ShowAssigned,
  [switch]$NoInstallOciCli
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'oci_cli_common.ps1')

$Config = Read-VipConfig -Path $ConfigPath -AllowMissing
$VnicId = Require-VipValue -Value (Get-ConfigValue -CliValue $VnicId -Config $Config -Keys @('vnic_id')) -Name 'VNIC OCID'
$AuthMode = Normalize-VipAuthMode -Value (Get-ConfigValue -CliValue $AuthMode -Config $Config -Keys @('auth_mode')) -Default 'instance_principal'
$OciConfigFile = Get-ConfigValue -CliValue $OciConfigFile -Config $Config -Keys @('oci_config_file', 'config_file')
$Profile = Get-ConfigValue -CliValue $Profile -Config $Config -Keys @('profile') -Default 'DEFAULT'
$Region = Get-ConfigValue -CliValue $Region -Config $Config -Keys @('region')

Ensure-OciCli -NoInstall:$NoInstallOciCli | Out-Null
$BaseArgs = Get-OciBaseArgs -AuthMode $AuthMode -ConfigFile $OciConfigFile -Profile $Profile -Region $Region
$PrivateIps = Get-PrivateIpsForVnic -VnicId $VnicId -BaseArgs $BaseArgs

if ($ShowAssigned) {
  Write-VipJsonResult -Result ([ordered]@{
    vnic_id = $VnicId
    mode = 'SHOW_ASSIGNED_ONLY'
    assigned_private_ips = @(Get-AssignedPrivateIpSummaries -PrivateIps $PrivateIps)
  })
  return
}

$RequestedIps = if ($AllSecondary) { @() } else { @(Get-SecondaryIps -CliIps $Ip -Config $Config) }
$PrivateIpsByAddress = @{}
foreach ($PrivateIp in $PrivateIps) {
  $Summary = Convert-PrivateIpSummary -PrivateIp $PrivateIp
  if ($Summary.ip_address) { $PrivateIpsByAddress[$Summary.ip_address] = $PrivateIp }
}

$Targets = New-Object System.Collections.Generic.List[object]
if ($AllSecondary) {
  foreach ($PrivateIp in $PrivateIps) {
    $Summary = Convert-PrivateIpSummary -PrivateIp $PrivateIp
    if (-not $Summary.is_primary) { $Targets.Add($PrivateIp) }
  }
} else {
  foreach ($VipIp in $RequestedIps) {
    if ($PrivateIpsByAddress.ContainsKey($VipIp)) { $Targets.Add($PrivateIpsByAddress[$VipIp]) }
  }
}

$WouldDelete = New-Object System.Collections.Generic.List[object]
$Deleted = New-Object System.Collections.Generic.List[object]
$SkippedPrimary = New-Object System.Collections.Generic.List[object]
$NotFound = New-Object System.Collections.Generic.List[string]

if (-not $AllSecondary) {
  foreach ($VipIp in $RequestedIps) {
    if (-not $PrivateIpsByAddress.ContainsKey($VipIp)) { $NotFound.Add($VipIp) }
  }
}

foreach ($Target in $Targets) {
  $Summary = Convert-PrivateIpSummary -PrivateIp $Target
  if ($Summary.is_primary) {
    $SkippedPrimary.Add($Summary)
    continue
  }

  if ($DryRun) {
    $Summary['would_delete'] = $true
    $WouldDelete.Add($Summary)
    continue
  }

  Invoke-OciJson -Arguments (@('network', 'private-ip', 'delete', '--private-ip-id', $Summary.id, '--force', '--output', 'json') + $BaseArgs) | Out-Null
  $Deleted.Add($Summary)
}

Write-VipJsonResult -Result ([ordered]@{
  vnic_id = $VnicId
  requested_ips = if ($AllSecondary) { 'ALL_SECONDARY' } else { @($RequestedIps) }
  would_delete = @($WouldDelete)
  deleted = @($Deleted)
  not_found = @($NotFound)
  skipped_primary = @($SkippedPrimary)
  dry_run = [bool]$DryRun
  mode = if ($DryRun) { 'DRY_RUN_NO_CHANGES' } else { 'DELETE' }
})

