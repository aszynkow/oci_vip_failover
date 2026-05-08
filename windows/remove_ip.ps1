param(
  [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "vip_config.json"),
  [string[]]$SecondaryIps
)

$ErrorActionPreference = "Stop"

function Get-SecondaryIpsFromConfig {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return @()
  }

  $Config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if (-not $Config.secondary_ips) {
    return @()
  }

  return @($Config.secondary_ips | ForEach-Object { [string]$_ })
}

if (-not $SecondaryIps -or $SecondaryIps.Count -eq 0) {
  $SecondaryIps = Get-SecondaryIpsFromConfig -Path $ConfigPath
}

if (-not $SecondaryIps -or $SecondaryIps.Count -eq 0) {
  throw "No secondary IPs found. Add secondary_ips to $ConfigPath or pass -SecondaryIps."
}

Write-Host "Secondary IPs: $($SecondaryIps -join ', ')"

# Find active IPv4 NIC
$NetConfig = Get-NetIPConfiguration |
  Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway } |
  Select-Object -First 1

if (-not $NetConfig) {
  throw "No active IPv4 interface with default gateway found."
}

$IfIndex = $NetConfig.InterfaceIndex
$IfAlias = $NetConfig.InterfaceAlias

Write-Host "Detected interface: $IfAlias / ifIndex $IfIndex"

foreach ($Ip in $SecondaryIps) {
  $ExistingIp = Get-NetIPAddress `
    -InterfaceIndex $IfIndex `
    -AddressFamily IPv4 `
    -IPAddress $Ip `
    -ErrorAction SilentlyContinue

  if ($ExistingIp) {
    Write-Host "Removing secondary IP $Ip"
    Remove-NetIPAddress `
      -InterfaceIndex $IfIndex `
      -IPAddress $Ip `
      -Confirm:$false
  } else {
    Write-Host "Secondary IP $Ip not found. Skipping."
  }
}

ipconfig /flushdns

Write-Host ""
Write-Host "Final config:"
ipconfig /all

Write-Host ""
Write-Host "Remaining IPv4 addresses:"
Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 |
  Format-Table IPAddress,PrefixLength,SkipAsSource,AddressState -Auto

Write-Host ""
Write-Host "Default route:"
Get-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix "0.0.0.0/0"
