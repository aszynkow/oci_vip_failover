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
  [switch]$SkipWindowsBind,
  [string]$WindowsAddScript,
  [switch]$DryRun,
  [switch]$NoInstallOciCli
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'oci_cli_common.ps1')

function Get-ImdsJson {
  param([string]$Path)

  $Headers = @{ Authorization = 'Bearer Oracle' }
  return Invoke-RestMethod -Uri "http://169.254.169.254/opc/v2$Path" -Headers $Headers -TimeoutSec 5
}

function Get-CurrentVmIdentity {
  $Instance = Get-ImdsJson -Path '/instance/'
  $Vnics = @(Get-ImdsJson -Path '/vnics/')
  if ($Vnics.Count -eq 0) { throw 'OCI instance metadata returned no VNICs.' }

  $Primary = $Vnics | Where-Object {
    (Get-JsonProperty -Object $_ -Names @('isPrimary', 'is-primary', 'is_primary')) -eq $true
  } | Select-Object -First 1
  if (-not $Primary) { $Primary = $Vnics[0] }

  return [ordered]@{
    instance_id = [string](Get-JsonProperty -Object $Instance -Names @('id'))
    hostname = [System.Net.Dns]::GetHostName()
    vnic_id = [string](Get-JsonProperty -Object $Primary -Names @('vnicId', 'vnic-id', 'vnic_id'))
    source = 'imds'
  }
}

function Get-TargetIdentity {
  param(
    [object]$Config,
    [string]$CliVnicId
  )

  if ($CliVnicId) {
    return [ordered]@{
      instance_id = ''
      hostname = [System.Net.Dns]::GetHostName()
      vnic_id = $CliVnicId
      source = 'cli'
    }
  }

  try {
    return Get-CurrentVmIdentity
  } catch {
    $FallbackVnic = Get-ConfigValue -Config $Config -Keys @('vnic_id')
    if (-not $FallbackVnic) {
      throw "Could not read OCI instance metadata and no -VnicId or vnic_id was supplied. $($_.Exception.Message)"
    }
    return [ordered]@{
      instance_id = ''
      hostname = [System.Net.Dns]::GetHostName()
      vnic_id = $FallbackVnic
      source = 'config'
    }
  }
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
    $ActionName = if ($CurrentVnicId -eq $TargetVnicId) { 'already_on_target' } else { 'move' }

    if ($CurrentVnicId -ne $TargetVnicId) {
      if ($DryRun) {
        $ActionName = 'would_move'
      } else {
        Invoke-OciJson -Arguments (@('network', 'vnic', 'assign-private-ip', '--vnic-id', $TargetVnicId, '--ip-address', $Vip.ip, '--unassign-if-already-assigned', '--output', 'json') + $BaseArgs) | Out-Null
        $Moved = $true
      }
    }

    $Actions.Add([ordered]@{
      ip = $Vip.ip
      private_ip_ocid = $Vip.private_ip_ocid
      from_vnic_id = $CurrentVnicId
      to_vnic_id = $TargetVnicId
      action = $ActionName
    })
  }

  $Assignments = if ($DryRun) {
    Get-CurrentAssignments -Vips $Vips -BaseArgs $BaseArgs
  } elseif ($Moved) {
    Wait-ForAssignments -Vips $Vips -TargetVnicId $TargetVnicId -BaseArgs $BaseArgs -TimeoutSecs $TimeoutSecs -PollSeconds $PollSeconds
  } else {
    Get-CurrentAssignments -Vips $Vips -BaseArgs $BaseArgs
  }

  return [ordered]@{
    actions = @($Actions)
    assignments = $Assignments
  }
}

function Invoke-WindowsBind {
  param(
    [string]$ScriptPath,
    [string]$ConfigPath,
    [string[]]$Ips
  )

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Windows add helper not found: $ScriptPath"
  }

  $Output = & $ScriptPath -ConfigPath $ConfigPath -SecondaryIps $Ips 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Windows add helper failed: $($Output -join [Environment]::NewLine)"
  }

  return [ordered]@{
    mode = 'BOUND'
    script = $ScriptPath
    output = ($Output -join [Environment]::NewLine)
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

$VipIps = @($Vips | ForEach-Object { $_.ip })
$WindowsResult = $null
if ($DryRun) {
  $WindowsResult = [ordered]@{ mode = 'DRY_RUN_NO_CHANGES'; would_bind_ips = @($VipIps) }
} elseif ($SkipWindowsBind) {
  $WindowsResult = [ordered]@{ mode = 'SKIPPED' }
} elseif (-not (Test-VipWindowsHost)) {
  $WindowsResult = [ordered]@{ mode = 'SKIPPED_NON_WINDOWS_HOST' }
} else {
  $WindowsSection = Get-ConfigSection -Config $Config -Name 'windows'
  $ConfiguredAddScript = Get-ConfigValue -CliValue $WindowsAddScript -Config $WindowsSection -Keys @('add_script')
  $InstallRoot = Split-Path -Parent $PSScriptRoot
  if (-not $ConfiguredAddScript) {
    $CandidateAddScripts = @(
      (Join-Path $InstallRoot 'windows_vms\add_ip.ps1'),
      (Join-Path $InstallRoot 'repo\windows_vms\add_ip.ps1')
    )
    $ConfiguredAddScript = $CandidateAddScripts | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $ConfiguredAddScript) { $ConfiguredAddScript = $CandidateAddScripts[0] }
  }

  $ResolvedAddScript = Resolve-VipPath -Path $ConfiguredAddScript
  if ($ConfiguredAddScript -and -not (Test-Path -LiteralPath $ResolvedAddScript) -and -not [System.IO.Path]::IsPathRooted($ConfiguredAddScript)) {
    $CandidateAddScripts = @(
      (Join-Path $InstallRoot $ConfiguredAddScript),
      (Join-Path (Join-Path $InstallRoot 'repo') $ConfiguredAddScript)
    )
    $ResolvedCandidate = $CandidateAddScripts | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($ResolvedCandidate) { $ResolvedAddScript = $ResolvedCandidate }
  }

  $WindowsResult = Invoke-WindowsBind -ScriptPath $ResolvedAddScript -ConfigPath (Resolve-VipPath -Path $ConfigPath) -Ips $VipIps
}

Write-VipJsonResult -Result ([ordered]@{
  mode = if ($DryRun) { 'DRY_RUN_NO_CHANGES' } else { 'TAKEOVER' }
  auth_mode = $AuthMode
  target = $Target
  oci_actions = @($MoveResult.actions)
  oci_assignments = $MoveResult.assignments
  windows = $WindowsResult
})

