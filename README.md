# OCI VIP Failover Scripts

Standalone VM-side scripts for OCI VIP failover on Windows.

The active implementation is PowerShell plus the OCI CLI. Copy or bootstrap this repo onto each Windows VM, keep a VM-local `vip_config.json`, and run the takeover script on the VM that should own the VIPs. The `aux_vm` PowerShell scripts install `oci-cli` with pip if `oci` is not found in `PATH`, refresh `PATH`, and retry the OCI call in the same run. Use `-NoInstallOciCli` to disable automatic install.

## Files

```text
.
|-- aux_vm/
|   |-- add_vnic_ip.ps1       # OCI CLI: create/assign secondary private IPs on a VNIC
|   |-- remove_vnic_ip.ps1    # OCI CLI: delete secondary private IPs from a VNIC
|   |-- startup_takeover.ps1  # OCI CLI: move configured private IP OCIDs to this VM VNIC
|   `-- oci_cli_common.ps1    # shared OCI CLI install, config, and JSON helpers
|-- windows_vms/
|   |-- add_ip.ps1            # local Windows NIC: bind VIPs to the OS interface
|   `-- remove_ip.ps1         # local Windows NIC: remove VIPs from the OS interface
|-- terraform/
|   |-- bootstrap.ps1.tmpl    # first-boot Git bootstrap for OCI Resource Manager VM builds
|   |-- main.tf               # Windows VM resource
|   |-- iam.tf                # optional policy and dynamic group resources
|   |-- variables.tf          # Terraform input variables
|   `-- schema.yaml           # OCI Resource Manager UI schema
|-- release/0.0.1/rm_vip.zip  # OCI Resource Manager stack package
|-- vip_config.example.json   # template config
`-- backup/                   # ignored backup of the previous Python scripts
```

`backup/` is intentionally in `.gitignore`. It keeps the old Python versions available locally as a reference, but the deployable repo is PowerShell-first.

## VM Setup

Install Git for Windows and Python 3 on each VM. Python is only needed when the scripts have to auto-install OCI CLI.

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

Create the local config on each VM:

```powershell
copy .\vip_config.example.json .\vip_config.json
```

Edit `vip_config.json` on each VM:

- `vnic_id`: that VM primary VNIC OCID.
- `secondary_ips`: the shared VIP addresses.
- `managed_vips[].private_ip_ocid`: the OCI private IP OCID for each VIP.
- `auth_mode`: usually `instance_principal` on OCI VMs, or `config_file` for local/admin runs.


## Deploy With OCI Resource Manager

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?region=home&zipUrl=https://github.com/aszynkow/oci_vip_failover/raw/main/release/0.0.1/rm_vip.zip)

1. Click **Deploy to Oracle Cloud** above.
2. In **Create Stack**:
   - Give your stack a **name**, for example _vip-failover-windows-vm_.
   - Select the **compartment** where you want the Windows VIP VM stack created.
   - Choose the existing **VCN**, **subnet**, and **availability domain**.
   - Review the Windows VM shape, boot volume size, bootstrap Git repository/ref, and IAM options.
   - If your tenancy has reached the Dynamic Group limit, leave **Create New Dynamic Group** unchecked and provide an existing dynamic group name whose matching rule includes the VM.
3. Click **Next**, then **Create**, and choose **Run apply** to provision the VM.
4. Monitor progress in **Resource Manager -> Stacks**. Once the job is **Succeeded**, the Windows VM is created and the first-boot bootstrap clones this repo, then copies `aux_vm` scripts to `C:\vip-agent\aux_vm`.

The Git bootstrap requires outbound HTTPS access from the VM to `api.github.com`, `github.com`, and GitHub release asset hosts. Use a public IP, NAT gateway, proxy, or another approved outbound path for private subnets.

## Terraform VM Bootstrap

The `terraform/` folder can create a Windows Server 2022 Standard VM in an existing compartment, VCN, and subnet. It does not inject an SSH key.

Minimum inputs are the OCI region, compartment OCID, VCN OCID, subnet OCID, availability domain, and any provider auth details your Terraform environment needs.

```powershell
cd .\terraform
terraform init
terraform apply `
  -var="region=ap-sydney-1" `
  -var="compartment_ocid=<compartment_ocid>" `
  -var="vcn_ocid=<vcn_ocid>" `
  -var="subnet_ocid=<subnet_ocid>" `
  -var="availability_domain=<availability_domain>"
```

The outputs include `primary_vnic_ocid`, which is the value to use as `vnic_id` in that VM's `vip_config.json`.

OCI Resource Manager uses `terraform/schema.yaml` to render LOV pickers for the target compartment, VCN, and subnet.

If `hostname_label` is left empty, Terraform derives both the primary VNIC `hostname_label` and instance metadata `hostname` from `vm_display_name` by removing special characters; an explicit `hostname_label` overrides the derived value.

When `create_iam_resources` is true, Terraform creates a compartment policy that allows the selected dynamic group to `manage virtual-network-family` in the target compartment. By default `create_dynamic_group` is false, so provide `existing_dynamic_group_name`; only enable `create_dynamic_group` when the tenancy has Dynamic Group quota available.

For defined tags, use the Terraform OCI provider's flat key format, for example `defined_tags = { "Operations.CostCenter" = "42" }`.

## Commands

Show private IPs currently assigned to the configured VNIC:

```powershell
.\aux_vm\add_vnic_ip.ps1 -ConfigPath .\vip_config.json -ShowAssigned
.\aux_vm\remove_vnic_ip.ps1 -ConfigPath .\vip_config.json -ShowAssigned
```

Add configured secondary IPs to the configured VNIC in OCI:

```powershell
.\aux_vm\add_vnic_ip.ps1 -ConfigPath .\vip_config.json
```

Starting fresh, create the secondary private IP resources and write `vip_config.json` in one run:

```powershell
.\aux_vm\add_vnic_ip.ps1 -VnicId <active_vm_primary_vnic_ocid> -Ip 10.200.0.213,10.200.0.214 -Region ap-sydney-1 -AuthMode config_file -WriteConfig -WriteConfigPath .\vip_config.json
```

Remove configured secondary IPs from the configured VNIC in OCI:

```powershell
.\aux_vm\remove_vnic_ip.ps1 -ConfigPath .\vip_config.json
```

Force takeover on the VM where the command is running:

```powershell
.\aux_vm\startup_takeover.ps1 -ConfigPath .\vip_config.json
```

This moves the configured OCI private IP resources to the current VM primary VNIC with `oci network vnic assign-private-ip --unassign-if-already-assigned`, then calls `windows_vms\add_ip.ps1` to bind the VIPs to the local Windows NIC.

Preview changes:

```powershell
.\aux_vm\add_vnic_ip.ps1 -ConfigPath .\vip_config.json -DryRun
.\aux_vm\remove_vnic_ip.ps1 -ConfigPath .\vip_config.json -DryRun
.\aux_vm\startup_takeover.ps1 -ConfigPath .\vip_config.json -DryRun
```

Use instance principal auth explicitly:

```powershell
.\aux_vm\startup_takeover.ps1 -ConfigPath .\vip_config.json -AuthMode instance_principal
```

Skip the local Windows NIC bind and move OCI private IP resources only:

```powershell
.\aux_vm\startup_takeover.ps1 -ConfigPath .\vip_config.json -SkipWindowsBind
```

`aux_vm\startup_takeover.ps1` moves the OCI private IP resource away from whichever VNIC currently owns it. It does not log in to the old VM to remove a stale Windows OS IP.

## OCI CLI Install Behavior

The `aux_vm` PowerShell scripts default to OCI instance principal auth. When instance principal auth is selected, they create `~/.oci/config` if needed with a profile containing `auth=instance_principal` and the configured or metadata-discovered region. Existing profiles are not overwritten.

Each `aux_vm` PowerShell script checks for `oci` before making OCI calls. If `oci` is missing, it tries:

```powershell
python -m pip install --user oci-cli
py -3 -m pip install --user oci-cli
python3 -m pip install --user oci-cli
```

After a successful install, the script refreshes common Python script paths in the current process and retries. If Python is not installed or the install fails, the script stops with the attempted command details.

## Windows NIC Helpers

Bind configured VIPs to the local Windows NIC:

```powershell
.\windows_vms\add_ip.ps1 -ConfigPath .\vip_config.json
```

Remove configured VIPs from the local Windows NIC:

```powershell
.\windows_vms\remove_ip.ps1 -ConfigPath .\vip_config.json
```

These helper scripts only change the local Windows OS network configuration. They do not move or delete OCI private IP resources.
