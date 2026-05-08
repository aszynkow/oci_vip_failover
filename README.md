# OCI VIP Failover Scripts

Standalone scripts for assigning, removing, and forcibly taking over OCI VIP secondary private IPs.

The scripts do not depend on the original VIP repo helper modules. They load `vip_config.json` from this repo root by default, support OCI config-file auth or instance-principal auth, and install the OCI Python SDK only if the `oci` package is missing. Use `--no-install-deps` to disable automatic package installation.

## Files

```text
.
├── add_ip.py                # create/assign secondary private IPs on a VNIC
├── remove_ip.py             # delete secondary private IPs from a VNIC
├── startup_takeover.py      # move configured private IP OCIDs to this VM VNIC
└── vip_config.example.json  # template config
```

## Config

Create a local config from the example:

```sh
cp vip_config.example.json vip_config.json
```

Set `region`, `vnic_id`, `secondary_ips`, and `managed_vips[].private_ip_ocid`.

## Commands

Add configured secondary IPs to the configured VNIC:

```sh
python add_ip.py --config vip_config.json
```

Remove configured secondary IPs from the configured VNIC:

```sh
python remove_ip.py --config vip_config.json
```

Force takeover on the VM where the command is running:

```powershell
python startup_takeover.py --config vip_config.json
```

Preview changes:

```sh
python add_ip.py --config vip_config.json --dry-run
python remove_ip.py --config vip_config.json --dry-run
python startup_takeover.py --config vip_config.json --dry-run
```

Use instance principal auth:

```sh
python startup_takeover.py --config vip_config.json --auth-mode instance_principal
```

`startup_takeover.py` moves the OCI private IP resource away from whichever VNIC currently owns it. It does not log in to the old VM to remove a stale Windows OS IP.
