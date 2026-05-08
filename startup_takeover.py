#!/usr/bin/env python3
"""Standalone startup takeover for OCI VIP secondary private IPs.

Run this on a VM that should take ownership of the configured VIPs. It discovers
the current VM primary VNIC from OCI instance metadata, moves the configured OCI
private IP resources to that VNIC, and binds the VIP addresses to the local
Windows NIC.
"""

from __future__ import annotations

import argparse
import importlib
import importlib.util
import ipaddress
import json
import platform
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent / "vip_config.json"
DEFAULT_PROFILE = "DEFAULT"
OCI_PACKAGE = "oci"


@dataclass(frozen=True)
class ManagedVip:
    ip: str
    private_ip_ocid: str


def ensure_oci_sdk(auto_install: bool) -> Any:
    if importlib.util.find_spec(OCI_PACKAGE):
        return importlib.import_module(OCI_PACKAGE)

    if not auto_install:
        raise SystemExit("Missing OCI Python SDK. Install it with: python -m pip install oci")

    print("OCI Python SDK not found; installing package 'oci'...", file=sys.stderr)
    install_commands = [
        [sys.executable, "-m", "pip", "install", OCI_PACKAGE],
        [sys.executable, "-m", "pip", "install", "--user", OCI_PACKAGE],
    ]
    last_result: subprocess.CompletedProcess[str] | None = None
    for command in install_commands:
        last_result = subprocess.run(command, capture_output=True, text=True)
        if last_result.returncode == 0:
            importlib.invalidate_caches()
            return importlib.import_module(OCI_PACKAGE)

    error = last_result.stderr.strip() if last_result else "unknown pip error"
    raise SystemExit(f"Could not install OCI Python SDK automatically: {error}")


def load_config(path: str | Path) -> dict[str, Any]:
    config_path = Path(path).expanduser()
    if not config_path.exists():
        raise SystemExit(f"Config file not found: {config_path}")

    try:
        with config_path.open("r", encoding="utf-8") as config_file:
            data = json.load(config_file)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {config_path}: {exc}") from exc

    if not isinstance(data, dict):
        raise SystemExit(f"{config_path} must contain a JSON object.")
    return data


def section(config: dict[str, Any], name: str) -> dict[str, Any]:
    value = config.get(name, {})
    return value if isinstance(value, dict) else {}


def config_value(
    cli_value: str | None,
    config: dict[str, Any],
    *keys: str,
    default: str | None = None,
) -> str | None:
    if cli_value:
        return cli_value
    for key in keys:
        value = config.get(key)
        if value not in (None, ""):
            return str(value)
    return default


def agent_value(config: dict[str, Any], key: str, default: Any = None) -> Any:
    agent = section(config, "agent")
    if key in agent and agent[key] not in (None, ""):
        return agent[key]
    return config.get(key, default)


def split_values(values: Iterable[str]) -> list[str]:
    items: list[str] = []
    for value in values:
        items.extend(part.strip() for part in str(value).replace(",", " ").split())
    return [item for item in items if item]


def normalize_ipv4(raw_ip: str) -> str:
    try:
        ip = ipaddress.ip_address(raw_ip)
    except ValueError as exc:
        raise SystemExit(f"Invalid IPv4 address {raw_ip!r}.") from exc
    if ip.version != 4:
        raise SystemExit(f"Only IPv4 VIPs are supported: {raw_ip}")
    return str(ip)


def secondary_ips(config: dict[str, Any]) -> list[str]:
    configured = config.get("secondary_ips", [])
    if isinstance(configured, str):
        raw_ips = split_values([configured])
    elif isinstance(configured, list):
        raw_ips = split_values([str(ip) for ip in configured])
    else:
        raise SystemExit("vip_config.json key 'secondary_ips' must be a string or list.")

    normalized: list[str] = []
    seen: set[str] = set()
    for raw_ip in raw_ips:
        ip = normalize_ipv4(raw_ip)
        if ip not in seen:
            normalized.append(ip)
            seen.add(ip)

    if not normalized:
        raise SystemExit("No secondary_ips configured in vip_config.json.")
    return normalized


def managed_vips(config: dict[str, Any]) -> list[ManagedVip]:
    configured = config.get("managed_vips")
    if configured:
        if not isinstance(configured, list):
            raise SystemExit("vip_config.json key 'managed_vips' must be a list.")

        vips: list[ManagedVip] = []
        for item in configured:
            if not isinstance(item, dict):
                raise SystemExit("Each managed_vips entry must be an object.")
            ip = item.get("ip") or item.get("private_ip")
            ocid = item.get("private_ip_ocid") or item.get("ocid")
            if not ip or not ocid:
                raise SystemExit("Each managed_vips entry must include ip and private_ip_ocid.")
            vips.append(ManagedVip(normalize_ipv4(str(ip)), str(ocid)))
        return vips

    ocids = config.get("private_ip_ocids") or config.get("vip_private_ip_ocids")
    if isinstance(ocids, str):
        ocid_list = split_values([ocids])
    elif isinstance(ocids, list):
        ocid_list = [str(ocid).strip() for ocid in ocids if str(ocid).strip()]
    else:
        single_ocid = config.get("private_ip_ocid") or config.get("vip_private_ip_ocid")
        ocid_list = [str(single_ocid).strip()] if single_ocid else []

    if not ocid_list:
        raise SystemExit(
            "Missing managed VIP private IP OCID. Add managed_vips or private_ip_ocids to vip_config.json."
        )

    ips = secondary_ips(config)
    if len(ips) != len(ocid_list):
        raise SystemExit(
            "VIP config mismatch: secondary_ips count does not match private_ip_ocids count. "
            "Use managed_vips for explicit ip/private_ip_ocid pairs."
        )
    return [ManagedVip(ip, ocid) for ip, ocid in zip(ips, ocid_list)]


def normalize_auth_mode(value: str | None) -> str:
    mode = str(value or "instance_principal").replace("-", "_").lower()
    if mode in {"instance", "instance_principals"}:
        return "instance_principal"
    if mode in {"config", "config_file", "cli"}:
        return "config_file"
    if mode not in {"instance_principal", "config_file"}:
        raise SystemExit("auth mode must be instance_principal or config_file.")
    return mode


def imds_json(path: str, timeout: int = 5) -> Any:
    request = urllib.request.Request(
        f"http://169.254.169.254/opc/v2{path}",
        headers={"Authorization": "Bearer Oracle"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def current_vm_identity(timeout: int = 5) -> dict[str, str]:
    instance = imds_json("/instance/", timeout=timeout)
    vnics = imds_json("/vnics/", timeout=timeout)
    primary = next((vnic for vnic in vnics if vnic.get("isPrimary")), vnics[0])
    return {
        "instance_id": str(instance.get("id") or ""),
        "hostname": platform.node(),
        "vnic_id": str(primary["vnicId"]),
        "source": "imds",
    }


def target_identity(config: dict[str, Any], args: argparse.Namespace) -> dict[str, str]:
    if args.vnic_id:
        return {
            "instance_id": "",
            "hostname": platform.node(),
            "vnic_id": args.vnic_id,
            "source": "cli",
        }

    try:
        identity = current_vm_identity()
    except Exception as exc:
        fallback_vnic = args.vnic_id or config_value(None, config, "vnic_id")
        if not fallback_vnic:
            raise SystemExit(
                "Could not read OCI instance metadata and no --vnic-id or vnic_id was supplied."
            ) from exc
        return {
            "instance_id": "",
            "hostname": platform.node(),
            "vnic_id": str(fallback_vnic),
            "source": "cli_or_config",
        }

    return identity


def network_client(oci: Any, config: dict[str, Any], args: argparse.Namespace, auth_mode: str) -> Any:
    region = config_value(args.region, config, "region")
    if auth_mode == "instance_principal":
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        base_config = {"region": region} if region else {}
        return oci.core.VirtualNetworkClient(
            base_config,
            signer=signer,
            retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY,
        )

    file_location = config_value(args.oci_config_file, config, "oci_config_file", "config_file")
    profile_name = config_value(args.profile, config, "profile", default=DEFAULT_PROFILE)
    if file_location:
        oci_config = oci.config.from_file(
            file_location=str(Path(file_location).expanduser()),
            profile_name=profile_name,
        )
    else:
        oci_config = oci.config.from_file(profile_name=profile_name)
    if region:
        oci_config["region"] = region
    oci.config.validate_config(oci_config)
    return oci.core.VirtualNetworkClient(oci_config, retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY)


def current_assignments(client: Any, vips: list[ManagedVip]) -> dict[str, dict[str, str | None]]:
    assignments: dict[str, dict[str, str | None]] = {}
    for vip in vips:
        private_ip = client.get_private_ip(vip.private_ip_ocid).data
        assignments[vip.ip] = {
            "private_ip_ocid": vip.private_ip_ocid,
            "vnic_id": getattr(private_ip, "vnic_id", None),
        }
    return assignments


def wait_for_assignments(
    client: Any,
    vips: list[ManagedVip],
    target_vnic_id: str,
    timeout_secs: int,
    poll_secs: int,
) -> dict[str, dict[str, str | None]]:
    deadline = time.monotonic() + timeout_secs
    last_assignments: dict[str, dict[str, str | None]] = {}
    while time.monotonic() < deadline:
        last_assignments = current_assignments(client, vips)
        if all(item["vnic_id"] == target_vnic_id for item in last_assignments.values()):
            return last_assignments
        time.sleep(poll_secs)
    raise TimeoutError(f"VIPs did not all move to VNIC {target_vnic_id} within {timeout_secs}s")


def move_vips(
    oci: Any,
    client: Any,
    vips: list[ManagedVip],
    target_vnic_id: str,
    dry_run: bool,
    timeout_secs: int,
    poll_secs: int,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, str | None]]]:
    moved = False
    actions: list[dict[str, Any]] = []

    for vip in vips:
        private_ip = client.get_private_ip(vip.private_ip_ocid).data
        current_vnic_id = getattr(private_ip, "vnic_id", None)
        action = {
            "ip": vip.ip,
            "private_ip_ocid": vip.private_ip_ocid,
            "from_vnic_id": current_vnic_id,
            "to_vnic_id": target_vnic_id,
            "action": "already_on_target" if current_vnic_id == target_vnic_id else "move",
        }
        if current_vnic_id != target_vnic_id and not dry_run:
            client.update_private_ip(
                vip.private_ip_ocid,
                oci.core.models.UpdatePrivateIpDetails(vnic_id=target_vnic_id),
            )
            moved = True
        if current_vnic_id != target_vnic_id and dry_run:
            action["action"] = "would_move"
        actions.append(action)

    if dry_run:
        return actions, current_assignments(client, vips)
    if moved:
        return actions, wait_for_assignments(client, vips, target_vnic_id, timeout_secs, poll_secs)
    return actions, current_assignments(client, vips)


def bind_windows_ips(ips: list[str], powershell: str) -> dict[str, Any]:
    ps_ips = json.dumps(ips)
    script = f"""
$ErrorActionPreference = "Stop"
$SecondaryIps = @'
{ps_ips}
'@ | ConvertFrom-Json
$SecondaryIps = @($SecondaryIps | ForEach-Object {{ [string]$_ }})

$NetConfig = Get-NetIPConfiguration |
  Where-Object {{ $_.IPv4Address -and $_.IPv4DefaultGateway }} |
  Select-Object -First 1

if (-not $NetConfig) {{
  throw "No active IPv4 interface with default gateway found."
}}

$IfIndex = $NetConfig.InterfaceIndex
$IfAlias = $NetConfig.InterfaceAlias
$PrimaryIpObj = $NetConfig.IPv4Address | Select-Object -First 1
$PrimaryIp = $PrimaryIpObj.IPAddress
$PrefixLength = $PrimaryIpObj.PrefixLength
$Gateway = $NetConfig.IPv4DefaultGateway.NextHop
$DnsServers = (Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4).ServerAddresses
$DnsSuffix = (Get-DnsClient -InterfaceIndex $IfIndex).ConnectionSpecificSuffix

$Result = [ordered]@{{
  interface_alias = $IfAlias
  interface_index = $IfIndex
  primary_ip = $PrimaryIp
  prefix_length = $PrefixLength
  gateway = $Gateway
  added = @()
  already_present = @()
}}

Set-NetIPInterface -InterfaceIndex $IfIndex -Dhcp Disabled

$PrimaryExists = Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $PrimaryIp -ErrorAction SilentlyContinue
if ($PrimaryExists) {{
  Set-NetIPAddress -InterfaceIndex $IfIndex -IPAddress $PrimaryIp -PrefixLength $PrefixLength -SkipAsSource $false | Out-Null
}} else {{
  New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $PrimaryIp -PrefixLength $PrefixLength -DefaultGateway $Gateway -SkipAsSource $false | Out-Null
}}

$RouteExists = Get-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
  Where-Object {{ $_.NextHop -eq $Gateway }}
if (-not $RouteExists) {{
  New-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix "0.0.0.0/0" -NextHop $Gateway | Out-Null
}}

foreach ($Ip in $SecondaryIps) {{
  if ($Ip -eq $PrimaryIp) {{
    throw "Secondary IP $Ip matches primary IP. Check input."
  }}

  $ExistingIp = Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $Ip -ErrorAction SilentlyContinue
  if ($ExistingIp) {{
    Set-NetIPAddress -InterfaceIndex $IfIndex -IPAddress $Ip -PrefixLength $PrefixLength -SkipAsSource $true | Out-Null
    $Result.already_present += $Ip
  }} else {{
    New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $Ip -PrefixLength $PrefixLength -Type Unicast -SkipAsSource $true | Out-Null
    $Result.added += $Ip
  }}
}}

if ($DnsServers -and $DnsServers.Count -gt 0) {{
  Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $DnsServers | Out-Null
}}

if ($DnsSuffix) {{
  Set-DnsClient -InterfaceIndex $IfIndex -ConnectionSpecificSuffix $DnsSuffix | Out-Null
}}

ipconfig /flushdns | Out-Null
$Result.remaining_ipv4 = @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 |
  Select-Object IPAddress, PrefixLength, SkipAsSource, AddressState)
$Result | ConvertTo-Json -Depth 5
"""
    result = subprocess.run(
        [
            powershell,
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"raw_output": result.stdout.strip()}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Path to vip_config.json.")
    parser.add_argument("--auth-mode", choices=["instance_principal", "config_file"], help="OCI auth mode.")
    parser.add_argument("--oci-config-file", help="Path to OCI CLI config file for config_file auth.")
    parser.add_argument("--profile", help="OCI config profile for config_file auth.")
    parser.add_argument("--region", help="OCI region override.")
    parser.add_argument("--vnic-id", help="Target VNIC OCID. Default: current VM primary VNIC from IMDS.")
    parser.add_argument("--wait-secs", type=int, help="Seconds to wait for OCI VNIC assignment.")
    parser.add_argument("--poll-secs", type=int, default=2, help="Seconds between OCI assignment checks.")
    parser.add_argument("--skip-windows-bind", action="store_true", help="Move OCI private IPs only.")
    parser.add_argument("--powershell-exe", help="PowerShell executable name or path.")
    parser.add_argument("--dry-run", action="store_true", help="Show intended OCI moves without changing OCI or Windows.")
    parser.add_argument("--no-install-deps", action="store_true", help="Do not auto-install missing Python packages.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = load_config(args.config)
    oci = ensure_oci_sdk(auto_install=not args.no_install_deps)

    vips = managed_vips(config)
    vm_identity = target_identity(config, args)
    target_vnic_id = vm_identity["vnic_id"]
    auth_mode = normalize_auth_mode(args.auth_mode or agent_value(config, "auth_mode", "instance_principal"))
    wait_secs = int(args.wait_secs or agent_value(config, "oci_wait_secs", 60))
    powershell = config_value(args.powershell_exe, section(config, "windows"), "powershell_exe", default="powershell")

    client = network_client(oci, config, args, auth_mode)
    oci_actions, assignments = move_vips(
        oci,
        client,
        vips,
        target_vnic_id,
        dry_run=args.dry_run,
        timeout_secs=wait_secs,
        poll_secs=args.poll_secs,
    )

    windows_result: dict[str, Any]
    if args.dry_run:
        windows_result = {"mode": "DRY_RUN_NO_CHANGES", "would_bind_ips": [vip.ip for vip in vips]}
    elif args.skip_windows_bind:
        windows_result = {"mode": "SKIPPED"}
    elif platform.system().lower() != "windows":
        windows_result = {"mode": "SKIPPED_NON_WINDOWS_HOST"}
    else:
        windows_result = bind_windows_ips([vip.ip for vip in vips], str(powershell))

    result = {
        "mode": "DRY_RUN_NO_CHANGES" if args.dry_run else "TAKEOVER",
        "auth_mode": auth_mode,
        "target": {
            "instance_id": vm_identity["instance_id"],
            "hostname": vm_identity["hostname"],
            "source": vm_identity["source"],
            "vnic_id": target_vnic_id,
        },
        "oci_actions": oci_actions,
        "oci_assignments": assignments,
        "windows": windows_result,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
