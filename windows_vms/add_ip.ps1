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

# Read current active IPv4 interface before disabling DHCP
$NetConfig = Get-NetIPConfiguration |
  Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway } |
  Select-Object -First 1

if (-not $NetConfig) {
  throw "No active IPv4 interface with default gateway found."
}

$IfIndex = $NetConfig.InterfaceIndex
$IfAlias = $NetConfig.InterfaceAlias
$PrimaryIpObj = $NetConfig.IPv4Address | Select-Object -First 1
$PrimaryIp = $PrimaryIpObj.IPAddress
$PrefixLength = $PrimaryIpObj.PrefixLength
$Gateway = $NetConfig.IPv4DefaultGateway.NextHop

$DnsServers = (Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4).ServerAddresses
$DnsSuffix = (Get-DnsClient -InterfaceIndex $IfIndex).ConnectionSpecificSuffix

Write-Host "Interface: $IfAlias / ifIndex $IfIndex"
Write-Host "Primary IP: $PrimaryIp"
Write-Host "Prefix: $PrefixLength"
Write-Host "Gateway: $Gateway"
Write-Host "DNS: $($DnsServers -join ', ')"
Write-Host "DNS suffix: $DnsSuffix"

# Disable DHCP after values are captured
Set-NetIPInterface -InterfaceIndex $IfIndex -Dhcp Disabled

# Keep primary IP as the normal source IP
$PrimaryExists = Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $PrimaryIp -ErrorAction SilentlyContinue

if ($PrimaryExists) {
  Set-NetIPAddress -InterfaceIndex $IfIndex -IPAddress $PrimaryIp -PrefixLength $PrefixLength -SkipAsSource $false
} else {
  New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $PrimaryIp -PrefixLength $PrefixLength -DefaultGateway $Gateway -SkipAsSource $false
}

# Ensure default route exists
$RouteExists = Get-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
  Where-Object { $_.NextHop -eq $Gateway }

if (-not $RouteExists) {
  New-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix "0.0.0.0/0" -NextHop $Gateway
}

# Add secondary IPs as non-source IPs
foreach ($Ip in $SecondaryIps) {
  if ($Ip -eq $PrimaryIp) {
    throw "Secondary IP $Ip matches primary IP. Check input."
  }

  Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $Ip -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false

  New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $Ip -PrefixLength $PrefixLength -Type Unicast -SkipAsSource $true
}

# Restore DNS from original DHCP config
if ($DnsServers -and $DnsServers.Count -gt 0) {
  Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $DnsServers
}

if ($DnsSuffix) {
  Set-DnsClient -InterfaceIndex $IfIndex -ConnectionSpecificSuffix $DnsSuffix
}

ipconfig /flushdns

ipconfig /all
Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 | Format-Table IPAddress,PrefixLength,SkipAsSource,AddressState -Auto
Get-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix "0.0.0.0/0"
