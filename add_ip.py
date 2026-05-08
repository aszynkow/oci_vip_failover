#!/usr/bin/env python3
"""Standalone assignment of secondary private IPs to an OCI VNIC."""

from __future__ import annotations

import argparse
import importlib
import importlib.util
import ipaddress
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent / "vip_config.json"
DEFAULT_PROFILE = "DEFAULT"
OCI_PACKAGE = "oci"


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
        return {}

    try:
        with config_path.open("r", encoding="utf-8") as config_file:
            data = json.load(config_file)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {config_path}: {exc}") from exc

    if not isinstance(data, dict):
        raise SystemExit(f"{config_path} must contain a JSON object.")
    return data


def config_value(cli_value: str | None, config: dict[str, Any], *keys: str, default: str | None = None) -> str | None:
    if cli_value:
        return cli_value
    for key in keys:
        value = config.get(key)
        if value not in (None, ""):
            return str(value)
    return default


def require_value(value: str | None, name: str) -> str:
    if value:
        return value
    raise SystemExit(f"Missing {name}. Pass it on the command line or set it in vip_config.json.")


def split_values(values: Iterable[str]) -> list[str]:
    items: list[str] = []
    for value in values:
        items.extend(part.strip() for part in str(value).replace(",", " ").split())
    return [item for item in items if item]


def secondary_ips(cli_ips: list[str] | None, config: dict[str, Any]) -> list[str]:
    if cli_ips:
        raw_ips = split_values(cli_ips)
    else:
        configured_ips = config.get("secondary_ips", [])
        if isinstance(configured_ips, str):
            raw_ips = split_values([configured_ips])
        elif isinstance(configured_ips, list):
            raw_ips = split_values([str(ip) for ip in configured_ips])
        else:
            raise SystemExit("vip_config.json key 'secondary_ips' must be a string or list of strings.")

    normalized: list[str] = []
    seen: set[str] = set()
    for raw_ip in raw_ips:
        try:
            ip = ipaddress.ip_address(raw_ip)
        except ValueError as exc:
            raise SystemExit(f"Invalid IP address {raw_ip!r}.") from exc
        if ip.version != 4:
            raise SystemExit(f"Only IPv4 secondary private IPs are supported: {raw_ip}")
        ip_text = str(ip)
        if ip_text not in seen:
            normalized.append(ip_text)
            seen.add(ip_text)

    if not normalized:
        raise SystemExit("No secondary IPs supplied. Use --ip or set secondary_ips in vip_config.json.")
    return normalized


def normalize_auth_mode(value: str | None) -> str:
    mode = str(value or "config_file").replace("-", "_").lower()
    if mode in {"instance", "instance_principals"}:
        return "instance_principal"
    if mode in {"config", "config_file", "cli"}:
        return "config_file"
    if mode not in {"instance_principal", "config_file"}:
        raise SystemExit("auth mode must be instance_principal or config_file.")
    return mode


def network_client(oci: Any, config: dict[str, Any], args: argparse.Namespace) -> Any:
    auth_mode = normalize_auth_mode(args.auth_mode or config.get("auth_mode"))
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


def list_private_ips(oci: Any, client: Any, vnic_id: str) -> list[Any]:
    return oci.pagination.list_call_get_all_results(client.list_private_ips, vnic_id=vnic_id).data


def private_ip_summary(private_ip: Any) -> dict[str, Any]:
    return {
        "id": getattr(private_ip, "id", None),
        "ip_address": getattr(private_ip, "ip_address", None),
        "is_primary": getattr(private_ip, "is_primary", None),
        "display_name": getattr(private_ip, "display_name", None),
        "lifecycle_state": getattr(private_ip, "lifecycle_state", None),
        "vnic_id": getattr(private_ip, "vnic_id", None),
    }


def assigned_ip_summaries(private_ips: list[Any]) -> list[dict[str, Any]]:
    summaries = [private_ip_summary(private_ip) for private_ip in private_ips]
    return sorted(summaries, key=lambda item: (not bool(item.get("is_primary")), item.get("ip_address") or ""))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Path to VIP JSON config.")
    parser.add_argument("--auth-mode", choices=["config_file", "instance_principal"], help="OCI auth mode.")
    parser.add_argument("--oci-config-file", help="Path to OCI CLI config file.")
    parser.add_argument("--profile", help="OCI config profile.")
    parser.add_argument("--region", help="Override OCI region.")
    parser.add_argument("--vnic-id", help="Target VNIC OCID.")
    parser.add_argument("--ip", dest="ips", action="append", help="Secondary IPv4 address to assign. Repeat or comma-separate.")
    parser.add_argument("--display-name-prefix", help="Display name prefix for new OCI private IP objects.")
    parser.add_argument("--dry-run", action="store_true", help="Show actions without creating private IPs.")
    parser.add_argument(
        "--show-assigned",
        "--show-assigned-ips",
        action="store_true",
        help="Show private IPs currently assigned to the VNIC and exit.",
    )
    parser.add_argument("--no-install-deps", action="store_true", help="Do not auto-install missing Python packages.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = load_config(args.config)
    oci = ensure_oci_sdk(auto_install=not args.no_install_deps)

    vnic_id = require_value(config_value(args.vnic_id, config, "vnic_id"), "VNIC OCID")
    client = network_client(oci, config, args)
    existing_private_ips = list_private_ips(oci, client, vnic_id)

    if args.show_assigned:
        print(json.dumps(
            {
                "vnic_id": vnic_id,
                "mode": "SHOW_ASSIGNED_ONLY",
                "assigned_private_ips": assigned_ip_summaries(existing_private_ips),
            },
            indent=2,
            sort_keys=True,
        ))
        return 0

    ips = secondary_ips(args.ips, config)
    display_name_prefix = config_value(args.display_name_prefix, config, "display_name_prefix", default="vip")
    existing_by_ip = {private_ip.ip_address: private_ip for private_ip in existing_private_ips}
    result: dict[str, Any] = {
        "vnic_id": vnic_id,
        "requested_ips": ips,
        "created": [],
        "already_present": [],
        "dry_run": args.dry_run,
        "mode": "DRY_RUN_NO_CHANGES" if args.dry_run else "CREATE",
    }

    for ip in ips:
        existing = existing_by_ip.get(ip)
        if existing:
            result["already_present"].append(private_ip_summary(existing))
            continue

        display_name = f"{display_name_prefix}-{ip.replace('.', '-')}" if display_name_prefix else None
        details = oci.core.models.CreatePrivateIpDetails(
            vnic_id=vnic_id,
            ip_address=ip,
            display_name=display_name,
        )

        if args.dry_run:
            result["created"].append({"ip_address": ip, "display_name": display_name, "would_create": True})
            continue

        response = client.create_private_ip(details)
        result["created"].append(private_ip_summary(response.data))

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
