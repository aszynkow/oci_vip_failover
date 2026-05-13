[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'vip_config.json'),
  [string]$AuthMode,
  [string]$OciConfigFile,
  [string]$Profile,
  [string]$Region,
  [string]$VnicId,
  [string[]]$Ip,
  [string]$DisplayNamePrefix,
  [switch]$DryRun,
  [switch]$ShowAssigned,
  [switch]$WriteConfig,
  [string]$WriteConfigPath,
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
$DisplayNamePrefix = Get-ConfigValue -CliValue $DisplayNamePrefix -Config $Config -Keys @('display_name_prefix') -Default 'vip'

Ensure-OciCli -NoInstall:$NoInstallOciCli | Out-Null
$BaseArgs = Get-OciBaseArgs -AuthMode $AuthMode -ConfigFile $OciConfigFile -Profile $Profile -Region $Region
$ExistingPrivateIps = Get-PrivateIpsForVnic -VnicId $VnicId -BaseArgs $BaseArgs

if ($ShowAssigned) {
  if ($WriteConfig -or $WriteConfigPath) {
    throw '-WriteConfig cannot be used with -ShowAssigned.'
  }

  Write-VipJsonResult -Result ([ordered]@{
    vnic_id = $VnicId
    mode = 'SHOW_ASSIGNED_ONLY'
    assigned_private_ips = @(Get-AssignedPrivateIpSummaries -PrivateIps $ExistingPrivateIps)
  })
  return
}

$RequestedIps = @(Get-SecondaryIps -CliIps $Ip -Config $Config)
$ExistingByIp = @{}
foreach ($PrivateIp in $ExistingPrivateIps) {
  $Summary = Convert-PrivateIpSummary -PrivateIp $PrivateIp
  if ($Summary.ip_address) { $ExistingByIp[$Summary.ip_address] = $PrivateIp }
}

$Created = New-Object System.Collections.Generic.List[object]
$AlreadyPresent = New-Object System.Collections.Generic.List[object]

foreach ($VipIp in $RequestedIps) {
  if ($ExistingByIp.ContainsKey($VipIp)) {
    $AlreadyPresent.Add((Convert-PrivateIpSummary -PrivateIp $ExistingByIp[$VipIp]))
    continue
  }

  $DisplayName = $null
  if ($DisplayNamePrefix) { $DisplayName = "$DisplayNamePrefix-$($VipIp.Replace('.', '-'))" }

  if ($DryRun) {
    $Created.Add([ordered]@{
      ip_address = $VipIp
      display_name = $DisplayName
      would_create = $true
    })
    continue
  }

  $CreateArgs = @('network', 'private-ip', 'create', '--vnic-id', $VnicId, '--ip-address', $VipIp, '--output', 'json')
  if ($DisplayName) { $CreateArgs += @('--display-name', $DisplayName) }
  $Response = Invoke-OciJson -Arguments ($CreateArgs + $BaseArgs)
  $Created.Add((Convert-PrivateIpSummary -PrivateIp $Response.data))
}

$Result = [ordered]@{
  vnic_id = $VnicId
  requested_ips = @($RequestedIps)
  created = @($Created)
  already_present = @($AlreadyPresent)
  dry_run = [bool]$DryRun
  mode = if ($DryRun) { 'DRY_RUN_NO_CHANGES' } else { 'CREATE' }
}

if ($WriteConfig) {
  $TargetConfigPath = if ($WriteConfigPath) { $WriteConfigPath } else { $ConfigPath }
  $ExistingConfiguredIps = @(Get-SecondaryIps -Config $Config -AllowEmpty)
  $AllIps = New-Object System.Collections.Generic.List[string]
  foreach ($ExistingIp in $ExistingConfiguredIps + $RequestedIps) {
    if ($AllIps -notcontains $ExistingIp) { $AllIps.Add($ExistingIp) }
  }

  $ManagedByIp = Get-ConfiguredManagedVipMap -Config $Config
  foreach ($Summary in @($AlreadyPresent) + @($Created)) {
    if ($Summary.ip_address -and $Summary.id) {
      $ManagedByIp[$Summary.ip_address] = $Summary.id
    }
  }

  Set-VipProperty -Object $Config -Name 'vnic_id' -Value $VnicId
  if ($Region) { Set-VipProperty -Object $Config -Name 'region' -Value $Region }
  if ($Profile) { Set-VipProperty -Object $Config -Name 'profile' -Value $Profile }
  if ($AuthMode) { Set-VipProperty -Object $Config -Name 'auth_mode' -Value $AuthMode }
  if ($OciConfigFile) { Set-VipProperty -Object $Config -Name 'oci_config_file' -Value $OciConfigFile }
  if ($DisplayNamePrefix) { Set-VipProperty -Object $Config -Name 'display_name_prefix' -Value $DisplayNamePrefix }
  Set-VipProperty -Object $Config -Name 'secondary_ips' -Value @($AllIps)

  $ManagedVips = foreach ($ConfiguredIp in $AllIps) {
    if ($ManagedByIp.ContainsKey($ConfiguredIp)) {
      [ordered]@{ ip = $ConfiguredIp; private_ip_ocid = $ManagedByIp[$ConfiguredIp] }
    }
  }
  Set-VipProperty -Object $Config -Name 'managed_vips' -Value @($ManagedVips)

  if ($DryRun) {
    $Result['would_write_config'] = [ordered]@{
      path = (Resolve-VipPath -Path $TargetConfigPath)
      config = $Config
    }
  } else {
    Write-VipConfig -Path $TargetConfigPath -Config $Config
    $Result['written_config'] = (Resolve-VipPath -Path $TargetConfigPath)
  }
}

Write-VipJsonResult -Result $Result

