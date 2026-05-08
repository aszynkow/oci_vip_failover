# OCI VIP Failover Scripts

Standalone VM-side scripts for OCI VIP failover.

The goal of this repo is simple: copy it onto each Windows VM, keep a local `vip_config.json` beside the scripts, and run the failover process from whichever VM should own the VIPs. The Python scripts do not depend on the original VIP repo helper modules. They support OCI config-file auth or instance-principal auth, and install the OCI Python SDK only if the `oci` package is missing. Use `--no-install-deps` to disable automatic package installation.

## Files

```text
.
|-- add_ip.py                # create/assign secondary private IPs on a VNIC
|-- remove_ip.py             # delete secondary private IPs from a VNIC
|-- startup_takeover.py      # move configured private IP OCIDs to this VM VNIC
|-- vip_config.example.json  # template config
`-- windows/
    |-- add_ip.ps1           # bind VIPs to the local Windows NIC
    `-- remove_ip.ps1        # remove VIPs from the local Windows NIC
```

## VM Setup

Install Git for Windows and Python 3 on each VM, then clone this repo. Replace `<repo-url>` with the GitHub URL after the repo is pushed.

```powershell
cd C:\
git clone <repo-url> C:\oci-vip-failover
cd C:\oci-vip-failover
```

If the repo already exists on the VM, update it instead:

```powershell
cd C:\oci-vip-failover
git pull
```

The expected install path is:

```text
C:\oci-vip-failover\
```

On each VM, create the local config:

```powershell
cd C:\oci-vip-failover
copy vip_config.example.json vip_config.json
```

Edit `vip_config.json` and set that VM primary `vnic_id`, the shared `secondary_ips`, and each `managed_vips[].private_ip_ocid`.

Python must be available in `PATH`. The scripts will install the OCI SDK automatically if it is missing.

## Config

Use one `vip_config.json` per VM. The VIP IPs and private IP OCIDs are shared, but `vnic_id` should be the primary VNIC OCID for the VM where the file is deployed.

## Commands

Add configured secondary IPs to the configured VNIC in OCI:

```sh
python add_ip.py --config vip_config.json
```

Starting fresh, create the secondary private IPs and write `vip_config.json` in one run:

```sh
python add_ip.py --vnic-id <active_vm_primary_vnic_ocid> --ip 10.200.0.213 --ip 10.200.0.214 --region ap-sydney-1 --write-config vip_config.json
```

`--write-config` creates or updates JSON config with `vnic_id`, `secondary_ips`, and `managed_vips[].private_ip_ocid` from the created or already-present OCI private IP resources. With no path, `--write-config` writes to the file passed by `--config`.

Remove configured secondary IPs from the configured VNIC in OCI:

```sh
python remove_ip.py --config vip_config.json
```

Force takeover on the VM where the command is running:

```powershell
python startup_takeover.py --config vip_config.json
```

This moves the configured OCI private IP resources to the current VM primary VNIC, then binds the VIPs to the local Windows NIC.

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

## Windows NIC Helpers

Bind configured VIPs to the local Windows NIC:

```powershell
.\windows\add_ip.ps1 -ConfigPath .\vip_config.json
```

Remove configured VIPs from the local Windows NIC:

```powershell
.\windows\remove_ip.ps1 -ConfigPath .\vip_config.json
```

These PowerShell scripts only change the local Windows OS network configuration. They do not move or delete OCI private IP resources.
