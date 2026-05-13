$script:VipRepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:OciCli = $null

function Test-VipValue {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $false }
  return $true
}

function Get-VipProperty {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) { return $null }
  if ($Object -is [hashtable]) {
    if ($Object.ContainsKey($Name)) { return $Object[$Name] }
    return $null
  }

  $Property = $Object.PSObject.Properties[$Name]
  if ($Property) { return $Property.Value }
  return $null
}

function Get-JsonProperty {
  param(
    [object]$Object,
    [string[]]$Names
  )

  foreach ($Name in $Names) {
    $Value = Get-VipProperty -Object $Object -Name $Name
    if (Test-VipValue -Value $Value) { return $Value }
  }
  return $null
}

function Set-VipProperty {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Value
  )

  if ($Object -is [hashtable]) {
    $Object[$Name] = $Value
    return
  }

  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
  }
}

function Resolve-VipPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
  if ([System.IO.Path]::IsPathRooted($Expanded)) { return $Expanded }
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Expanded)
}

function Read-VipConfig {
  param(
    [string]$Path,
    [switch]$AllowMissing
  )

  $Resolved = Resolve-VipPath -Path $Path
  if (-not (Test-Path -LiteralPath $Resolved)) {
    if ($AllowMissing) { return [pscustomobject]@{} }
    throw "Config file not found: $Resolved"
  }

  try {
    $Json = Get-Content -LiteralPath $Resolved -Raw
    if ([string]::IsNullOrWhiteSpace($Json)) { return [pscustomobject]@{} }
    return $Json | ConvertFrom-Json
  } catch {
    throw "Invalid JSON in $Resolved`: $($_.Exception.Message)"
  }
}

function Write-VipConfig {
  param(
    [string]$Path,
    [object]$Config
  )

  $Resolved = Resolve-VipPath -Path $Path
  $Parent = Split-Path -Parent $Resolved
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }

  $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Resolved -Encoding UTF8
}

function Get-ConfigValue {
  param(
    [object]$CliValue,
    [object]$Config,
    [string[]]$Keys,
    [string]$Default = $null
  )

  if (Test-VipValue -Value $CliValue) { return [string]$CliValue }
  foreach ($Key in $Keys) {
    $Value = Get-VipProperty -Object $Config -Name $Key
    if (Test-VipValue -Value $Value) { return [string]$Value }
  }
  return $Default
}

function Get-ConfigSection {
  param(
    [object]$Config,
    [string]$Name
  )

  $Value = Get-VipProperty -Object $Config -Name $Name
  if ($null -eq $Value) { return [pscustomobject]@{} }
  return $Value
}

function Get-AgentValue {
  param(
    [object]$Config,
    [string]$Key,
    [object]$Default = $null
  )

  $Agent = Get-ConfigSection -Config $Config -Name 'agent'
  $AgentValue = Get-VipProperty -Object $Agent -Name $Key
  if (Test-VipValue -Value $AgentValue) { return $AgentValue }

  $RootValue = Get-VipProperty -Object $Config -Name $Key
  if (Test-VipValue -Value $RootValue) { return $RootValue }
  return $Default
}

function Split-VipValues {
  param([object[]]$Values)

  $Items = New-Object System.Collections.Generic.List[string]
  foreach ($Value in $Values) {
    if ($null -eq $Value) { continue }
    $Parts = ([string]$Value).Replace(',', ' ').Split([char[]]@(' ', "`t", "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($Part in $Parts) {
      $Trimmed = $Part.Trim()
      if ($Trimmed) { $Items.Add($Trimmed) }
    }
  }
  return @($Items)
}

function Normalize-VipIpv4 {
  param([string]$IpAddress)

  $Parsed = $null
  if (-not [System.Net.IPAddress]::TryParse($IpAddress, [ref]$Parsed)) {
    throw "Invalid IPv4 address '$IpAddress'."
  }
  if ($Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "Only IPv4 VIPs are supported: $IpAddress"
  }
  return $Parsed.ToString()
}

function Get-SecondaryIps {
  param(
    [object[]]$CliIps,
    [object]$Config,
    [switch]$AllowEmpty
  )

  if ($CliIps -and $CliIps.Count -gt 0) {
    $RawIps = Split-VipValues -Values $CliIps
  } else {
    $Configured = Get-VipProperty -Object $Config -Name 'secondary_ips'
    if ($null -eq $Configured) {
      $RawIps = @()
    } elseif ($Configured -is [array]) {
      $RawIps = Split-VipValues -Values $Configured
    } else {
      $RawIps = Split-VipValues -Values @($Configured)
    }
  }

  $Seen = @{}
  $Normalized = New-Object System.Collections.Generic.List[string]
  foreach ($RawIp in $RawIps) {
    $Ip = Normalize-VipIpv4 -IpAddress $RawIp
    if (-not $Seen.ContainsKey($Ip)) {
      $Seen[$Ip] = $true
      $Normalized.Add($Ip)
    }
  }

  if (-not $AllowEmpty -and $Normalized.Count -eq 0) {
    throw "No secondary IPs supplied. Use -Ip or set secondary_ips in vip_config.json."
  }
  return @($Normalized)
}

function Normalize-VipAuthMode {
  param(
    [string]$Value,
    [string]$Default = 'config_file'
  )

  $Mode = $Value
  if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = $Default }
  $Mode = $Mode.Replace('-', '_').ToLowerInvariant()

  if ($Mode -in @('instance', 'instance_principals')) { return 'instance_principal' }
  if ($Mode -in @('config', 'config_file', 'cli')) { return 'config_file' }
  if ($Mode -notin @('instance_principal', 'config_file')) {
    throw "Auth mode must be instance_principal or config_file."
  }
  return $Mode
}


function Get-DefaultOciConfigPath {
  if ($env:OCI_CLI_CONFIG_FILE) { return (Resolve-VipPath -Path $env:OCI_CLI_CONFIG_FILE) }
  if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE '.oci\config') }
  if ($env:HOME) { return (Join-Path $env:HOME '.oci/config') }
  throw 'Could not determine OCI CLI config path. Set OCI_CLI_CONFIG_FILE or USERPROFILE/HOME.'
}

function Get-ImdsRegion {
  try {
    $Headers = @{ Authorization = 'Bearer Oracle' }
    $Region = Invoke-RestMethod -Uri 'http://169.254.169.254/opc/v2/instance/region' -Headers $Headers -TimeoutSec 3
    if (Test-VipValue -Value $Region) { return [string]$Region }
  } catch {
    return $null
  }
  return $null
}

function Test-OciConfigHasProfile {
  param(
    [string]$Path,
    [string]$Profile
  )

  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $ProfileHeader = "[$Profile]"
  foreach ($Line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
    if ($Line.Trim() -eq $ProfileHeader) { return $true }
  }
  return $false
}

function Ensure-OciInstancePrincipalConfig {
  param(
    [string]$ConfigFile,
    [string]$Profile,
    [string]$Region
  )

  $ConfigPath = if (Test-VipValue -Value $ConfigFile) { Resolve-VipPath -Path $ConfigFile } else { Get-DefaultOciConfigPath }
  $ProfileName = if (Test-VipValue -Value $Profile) { $Profile } else { 'DEFAULT' }
  $ConfigRegion = if (Test-VipValue -Value $Region) { $Region } else { Get-ImdsRegion }
  $Parent = Split-Path -Parent $ConfigPath
  if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }

  $ProfileBlock = New-Object System.Collections.Generic.List[string]
  $ProfileBlock.Add("[$ProfileName]")
  $ProfileBlock.Add('auth=instance_principal')
  if (Test-VipValue -Value $ConfigRegion) {
    $ProfileBlock.Add("region=$ConfigRegion")
  }

  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Set-Content -LiteralPath $ConfigPath -Value $ProfileBlock -Encoding ascii
    return $ConfigPath
  }

  if (-not (Test-OciConfigHasProfile -Path $ConfigPath -Profile $ProfileName)) {
    Add-Content -LiteralPath $ConfigPath -Value '' -Encoding ascii
    Add-Content -LiteralPath $ConfigPath -Value $ProfileBlock -Encoding ascii
  }

  return $ConfigPath
}

function Get-OciBaseArgs {
  param(
    [string]$AuthMode,
    [string]$ConfigFile,
    [string]$Profile,
    [string]$Region
  )

  $Args = New-Object System.Collections.Generic.List[string]
  if ($AuthMode -eq 'instance_principal') {
    Ensure-OciInstancePrincipalConfig -ConfigFile $ConfigFile -Profile $Profile -Region $Region | Out-Null
    $Args.Add('--auth')
    $Args.Add('instance_principal')
  } else {
    if (Test-VipValue -Value $ConfigFile) {
      $Args.Add('--config-file')
      $Args.Add((Resolve-VipPath -Path $ConfigFile))
    }
    if (Test-VipValue -Value $Profile) {
      $Args.Add('--profile')
      $Args.Add($Profile)
    }
  }
  if (Test-VipValue -Value $Region) {
    $Args.Add('--region')
    $Args.Add($Region)
  }
  return @($Args)
}

function Refresh-OciCliPath {
  $Candidates = New-Object System.Collections.Generic.List[string]

  $Candidates.Add('C:\oci-cli-bin')
  $Candidates.Add('C:\oci-cli\Scripts')
  $Candidates.Add('C:\oci-python')
  $Candidates.Add('C:\oci-python\Scripts')

  if ($env:APPDATA) {
    Get-ChildItem -Directory -Path (Join-Path $env:APPDATA 'Python\Python*\Scripts') -ErrorAction SilentlyContinue |
      ForEach-Object { $Candidates.Add($_.FullName) }
  }
  if ($env:LOCALAPPDATA) {
    Get-ChildItem -Directory -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\Scripts') -ErrorAction SilentlyContinue |
      ForEach-Object { $Candidates.Add($_.FullName) }
  }
  if ($env:USERPROFILE) {
    $Candidates.Add((Join-Path $env:USERPROFILE 'bin'))
    $Candidates.Add((Join-Path $env:USERPROFILE '.local\bin'))
    $Candidates.Add((Join-Path $env:USERPROFILE 'oci-cli\Scripts'))
  }
  if ($env:HOME) {
    $Candidates.Add((Join-Path $env:HOME 'bin'))
    $Candidates.Add((Join-Path $env:HOME '.local/bin'))
  }

  $CurrentParts = @($env:Path -split [System.IO.Path]::PathSeparator)
  foreach ($Candidate in $Candidates) {
    if ((Test-Path -LiteralPath $Candidate) -and ($CurrentParts -notcontains $Candidate)) {
      $env:Path = "$env:Path$([System.IO.Path]::PathSeparator)$Candidate"
    }
  }
}

function New-DirectoryIfMissing {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-ExternalOutputToHost {
  param([object[]]$Output)

  foreach ($Line in @($Output)) {
    if ($null -ne $Line) { Write-Host ([string]$Line) }
  }
}

function Install-OciCliWithOracleInstaller {
  param([System.Collections.Generic.List[string]]$Errors)

  Write-Host "Trying Oracle OCI CLI PowerShell installer..." -ForegroundColor Yellow

  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch { }

  $TempRoot = [System.IO.Path]::GetTempPath()
  $InstallerPath = Join-Path $TempRoot 'install-oci-cli.ps1'
  $InstallerUri = 'https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1'

  try {
    Invoke-WebRequest -Uri $InstallerUri -OutFile $InstallerPath -UseBasicParsing -ErrorAction Stop | Out-Null
  } catch {
    $Errors.Add("OCI CLI PowerShell installer download failed: $($_.Exception.Message)")
    return $false
  }

  $PowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if (-not $PowerShell) { $PowerShell = Get-Command powershell -ErrorAction SilentlyContinue }
  if (-not $PowerShell) {
    $Errors.Add('powershell.exe was not found to run the OCI CLI installer.')
    return $false
  }

  $InstallDir = 'C:\oci-cli'
  $ExecDir = 'C:\oci-cli-bin'
  $PythonInstallLocation = 'C:\oci-python'

  try {
    New-DirectoryIfMissing -Path $InstallDir
    New-DirectoryIfMissing -Path $ExecDir
    New-DirectoryIfMissing -Path $PythonInstallLocation
  } catch {
    $Errors.Add("Could not create short OCI CLI install directories under C:\. Run PowerShell as Administrator or install OCI CLI manually. $($_.Exception.Message)")
    return $false
  }

  $InstallerArgs = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $InstallerPath,
    '-AcceptAllDefaults',
    '-InstallDir',
    $InstallDir,
    '-ExecDir',
    $ExecDir,
    '-PythonInstallLocation',
    $PythonInstallLocation
  )

  $Output = & $PowerShell.Source @InstallerArgs 2>&1
  $ExitCode = $LASTEXITCODE
  Write-ExternalOutputToHost -Output $Output

  if ($ExitCode -ne 0) {
    $Errors.Add("OCI CLI PowerShell installer failed with exit code $ExitCode")
    return $false
  }

  Refresh-OciCliPath
  $Command = Get-Command oci -ErrorAction SilentlyContinue
  if ($Command) { return $true }

  $Errors.Add('OCI CLI PowerShell installer completed, but oci was not found in PATH. Expected locations include C:\oci-cli-bin, C:\oci-cli\Scripts, %USERPROFILE%\bin, and Python Scripts directories.')
  return $false
}

function Install-OciCli {
  Write-Host "OCI CLI was not found in PATH. Installing oci-cli..." -ForegroundColor Yellow

  $Attempts = @(
    @{ Exe = 'python'; Args = @('-m', 'pip', 'install', '--user', 'oci-cli') },
    @{ Exe = 'py'; Args = @('-3', '-m', 'pip', 'install', '--user', 'oci-cli') },
    @{ Exe = 'python3'; Args = @('-m', 'pip', 'install', '--user', 'oci-cli') }
  )

  $Errors = New-Object System.Collections.Generic.List[string]
  foreach ($Attempt in $Attempts) {
    $Command = Get-Command $Attempt.Exe -ErrorAction SilentlyContinue
    if (-not $Command) { continue }

    Write-Host "Trying: $($Attempt.Exe) $($Attempt.Args -join ' ')" -ForegroundColor Yellow
    $Output = & $Command.Source @($Attempt.Args) 2>&1
    $ExitCode = $LASTEXITCODE
    Write-ExternalOutputToHost -Output $Output

    if ($ExitCode -eq 0) {
      Refresh-OciCliPath
      return
    }
    $Errors.Add("$($Attempt.Exe) $($Attempt.Args -join ' ') failed with exit code $ExitCode")
  }

  if ($Errors.Count -eq 0) {
    $Errors.Add('No python, py, or python3 executable was found.')
  }

  if (Install-OciCliWithOracleInstaller -Errors $Errors) { return }

  $Detail = $Errors -join '; '
  throw "Could not install OCI CLI automatically. $Detail"
}

function Ensure-OciCli {
  param([switch]$NoInstall)

  Refresh-OciCliPath
  $Command = Get-Command oci -ErrorAction SilentlyContinue
  if ($Command) {
    $script:OciCli = $Command.Source
    return $script:OciCli
  }

  if ($NoInstall) {
    throw "OCI CLI not found. Install it with the Oracle OCI CLI PowerShell installer or rerun without -NoInstallOciCli."
  }

  Install-OciCli
  Refresh-OciCliPath
  $Command = Get-Command oci -ErrorAction SilentlyContinue
  if (-not $Command) {
    throw "OCI CLI was installed but oci still is not in PATH. Open a new shell or add C:\oci-cli-bin or the Python Scripts directory to PATH."
  }

  $script:OciCli = $Command.Source
  return $script:OciCli
}

function Invoke-OciJson {
  param([string[]]$Arguments)

  if (-not $script:OciCli) { Ensure-OciCli | Out-Null }

  $Output = & $script:OciCli @Arguments
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) {
    throw "OCI CLI failed with exit code $ExitCode`: oci $($Arguments -join ' ')"
  }

  $Text = ($Output -join [Environment]::NewLine).Trim()
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  try {
    return $Text | ConvertFrom-Json
  } catch {
    throw "OCI CLI did not return valid JSON for: oci $($Arguments -join ' '). Output: $Text"
  }
}

function Convert-PrivateIpSummary {
  param([object]$PrivateIp)

  return [ordered]@{
    id = [string](Get-JsonProperty -Object $PrivateIp -Names @('id'))
    ip_address = [string](Get-JsonProperty -Object $PrivateIp -Names @('ip-address', 'ip_address', 'ipAddress'))
    is_primary = [bool](Get-JsonProperty -Object $PrivateIp -Names @('is-primary', 'is_primary', 'isPrimary'))
    display_name = [string](Get-JsonProperty -Object $PrivateIp -Names @('display-name', 'display_name', 'displayName'))
    lifecycle_state = [string](Get-JsonProperty -Object $PrivateIp -Names @('lifecycle-state', 'lifecycle_state', 'lifecycleState'))
    vnic_id = [string](Get-JsonProperty -Object $PrivateIp -Names @('vnic-id', 'vnic_id', 'vnicId'))
  }
}

function Get-AssignedPrivateIpSummaries {
  param([object[]]$PrivateIps)

  $Summaries = foreach ($PrivateIp in $PrivateIps) { Convert-PrivateIpSummary -PrivateIp $PrivateIp }
  return @($Summaries | Sort-Object -Property @{ Expression = { if ($_.is_primary) { 0 } else { 1 } } }, ip_address)
}

function Get-PrivateIpsForVnic {
  param(
    [string]$VnicId,
    [string[]]$BaseArgs
  )

  $Result = Invoke-OciJson -Arguments (@('network', 'private-ip', 'list', '--vnic-id', $VnicId, '--all', '--output', 'json') + $BaseArgs)
  if ($null -eq $Result) { return @() }
  return @($Result.data)
}

function Get-PrivateIpById {
  param(
    [string]$PrivateIpId,
    [string[]]$BaseArgs
  )

  $Result = Invoke-OciJson -Arguments (@('network', 'private-ip', 'get', '--private-ip-id', $PrivateIpId, '--output', 'json') + $BaseArgs)
  return $Result.data
}

function Get-ConfiguredManagedVipMap {
  param([object]$Config)

  $Map = @{}
  $Managed = Get-VipProperty -Object $Config -Name 'managed_vips'
  if ($null -eq $Managed) { return $Map }

  foreach ($Item in @($Managed)) {
    $Ip = Get-JsonProperty -Object $Item -Names @('ip', 'private_ip')
    $Ocid = Get-JsonProperty -Object $Item -Names @('private_ip_ocid', 'ocid')
    if ((Test-VipValue -Value $Ip) -and (Test-VipValue -Value $Ocid)) {
      $Map[[string]$Ip] = [string]$Ocid
    }
  }
  return $Map
}

function Get-ManagedVips {
  param([object]$Config)

  $Managed = Get-VipProperty -Object $Config -Name 'managed_vips'
  if ($Managed) {
    $Vips = New-Object System.Collections.Generic.List[object]
    foreach ($Item in @($Managed)) {
      $Ip = Get-JsonProperty -Object $Item -Names @('ip', 'private_ip')
      $Ocid = Get-JsonProperty -Object $Item -Names @('private_ip_ocid', 'ocid')
      if (-not (Test-VipValue -Value $Ip) -or -not (Test-VipValue -Value $Ocid)) {
        throw 'Each managed_vips entry must include ip and private_ip_ocid.'
      }
      $Vips.Add([pscustomobject]@{
        ip = Normalize-VipIpv4 -IpAddress ([string]$Ip)
        private_ip_ocid = [string]$Ocid
      })
    }
    return @($Vips)
  }

  $Ocids = $null
  foreach ($Name in @('private_ip_ocids', 'vip_private_ip_ocids', 'private_ip_ocid', 'vip_private_ip_ocid')) {
    $Value = Get-VipProperty -Object $Config -Name $Name
    if (Test-VipValue -Value $Value) {
      $Ocids = $Value
      break
    }
  }
  if (-not $Ocids) {
    throw 'Missing managed VIP private IP OCID. Add managed_vips or private_ip_ocids to vip_config.json.'
  }

  $OcidList = if ($Ocids -is [array]) { @($Ocids | ForEach-Object { [string]$_ }) } else { Split-VipValues -Values @($Ocids) }
  $Ips = Get-SecondaryIps -Config $Config
  if ($Ips.Count -ne $OcidList.Count) {
    throw 'VIP config mismatch: secondary_ips count does not match private_ip_ocids count. Use managed_vips for explicit pairs.'
  }

  $Vips = for ($Index = 0; $Index -lt $Ips.Count; $Index++) {
    [pscustomobject]@{
      ip = $Ips[$Index]
      private_ip_ocid = $OcidList[$Index]
    }
  }
  return @($Vips)
}


function Test-VipWindowsHost {
  $Variable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
  if ($Variable) { return [bool]$Variable.Value }
  return ($env:OS -eq 'Windows_NT')
}

function Require-VipValue {
  param(
    [string]$Value,
    [string]$Name
  )

  if (Test-VipValue -Value $Value) { return $Value }
  throw "Missing $Name. Pass it on the command line or set it in vip_config.json."
}

function Write-VipJsonResult {
  param([object]$Result)

  $Result | ConvertTo-Json -Depth 20
}

