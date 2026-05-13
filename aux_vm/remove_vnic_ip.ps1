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

if ($AllSecondary) {
  $RequestedIps = @()
} else {
  $RequestedIps = Get-SecondaryIps -CliIps $Ip -Config $Config
}
$PrivateIpsByAddress = @{}
foreach ($PrivateIp in $PrivateIps) {
  $Summary = Convert-PrivateIpSummary -PrivateIp $PrivateIp
  if ($Summary.ip_address) { $PrivateIpsByAddress[$Summary.ip_address] = $PrivateIp }
}

$Targets = New-Object System.Collections.Generic.List[object]
if ($AllSecondary) {
  foreach ($PrivateIp in $PrivateIps) {
    $Summary = Convert-PrivateIpSummary -PrivateIp $PrivateIp
    if (-not $Summary.is_primary) { [void]$Targets.Add($PrivateIp) }
  }
} else {
  foreach ($VipIp in $RequestedIps) {
    if ($PrivateIpsByAddress.ContainsKey($VipIp)) { [void]$Targets.Add($PrivateIpsByAddress[$VipIp]) }
  }
}

$WouldDelete = New-Object System.Collections.Generic.List[object]
$Deleted = New-Object System.Collections.Generic.List[object]
$SkippedPrimary = New-Object System.Collections.Generic.List[object]
$NotFound = New-Object System.Collections.Generic.List[string]

if (-not $AllSecondary) {
  foreach ($VipIp in $RequestedIps) {
    if (-not $PrivateIpsByAddress.ContainsKey($VipIp)) { [void]$NotFound.Add($VipIp) }
  }
}

foreach ($Target in $Targets) {
  $Summary = Convert-PrivateIpSummary -PrivateIp $Target
  if ($Summary.is_primary) {
    [void]$SkippedPrimary.Add($Summary)
    continue
  }

  if ($DryRun) {
    $Summary['would_delete'] = $true
    [void]$WouldDelete.Add($Summary)
    continue
  }

  $DeleteArgs = New-Object System.Collections.Generic.List[string]
  foreach ($Arg in @('network', 'private-ip', 'delete', '--private-ip-id', $Summary.id, '--force', '--output', 'json')) {
    [void]$DeleteArgs.Add([string]$Arg)
  }
  foreach ($Arg in $BaseArgs) { [void]$DeleteArgs.Add([string]$Arg) }
  Invoke-OciJson -Arguments $DeleteArgs.ToArray() | Out-Null
  [void]$Deleted.Add($Summary)
}

if ($AllSecondary) {
  $RequestedResult = 'ALL_SECONDARY'
} else {
  $RequestedResult = [string[]]$RequestedIps
}

if ($DryRun) {
  $ResultMode = 'DRY_RUN_NO_CHANGES'
} else {
  $ResultMode = 'DELETE'
}

Write-VipJsonResult -Result ([ordered]@{
  vnic_id = $VnicId
  requested_ips = $RequestedResult
  would_delete = $WouldDelete.ToArray()
  deleted = $Deleted.ToArray()
  not_found = $NotFound.ToArray()
  skipped_primary = $SkippedPrimary.ToArray()
  dry_run = [bool]$DryRun
  mode = $ResultMode
})

