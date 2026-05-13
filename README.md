# OCI VIP Failover Scripts

PowerShell-first tooling for moving OCI secondary private IPs between Windows VMs and binding those VIPs to the local Windows NIC.

## Deploy With OCI Resource Manager

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?region=home&zipUrl=https://github.com/aszynkow/oci_vip_failover/raw/main/release/0.0.1/rm_vip.zip)

1. Click **Deploy to Oracle Cloud** above.
2. In **Create Stack**:
   - Give the stack a name, for example _vip-failover-windows-vm_.
   - Select the compartment where the Windows VIP VM should be created.
   - Choose the existing VCN, subnet, and availability domain.
   - Review the Windows VM shape, boot volume size, hostname, bootstrap Git repository/ref, and IAM options.
   - If your tenancy has reached the Dynamic Group limit, leave **Create New Dynamic Group** unchecked and provide an existing dynamic group name whose matching rule includes the VM.
3. Click **Next**, then **Create**, and choose **Run apply**.
4. When the Resource Manager job succeeds, the VM is created and Windows first boot runs the bootstrap script.

The bootstrap installs Git for Windows if needed, clones this repository from `https://github.com/aszynkow/oci_vip_failover`, and copies `aux_vm` scripts to:

```text
C:\vip-agent\aux_vm
```

The clone works as long as the VM has outbound HTTPS egress to GitHub. A private subnet with a NAT Gateway is fine; a public subnet needs an Internet Gateway and a public IP. NSGs/security lists must allow outbound TCP 443.

Bootstrap logs are written to:

```text
C:\ProgramData\vip-agent\bootstrap\bootstrap.log
C:\ProgramData\vip-agent\bootstrap\git-clone.log
```

## Folder Layout

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
`-- vip_config.example.json   # template config
```

`aux_vm` scripts call OCI APIs through OCI CLI. They create, remove, list, or move OCI private IP resources.

`windows_vms` scripts only change the local Windows OS NIC configuration. They do not create, delete, or move OCI private IP resources.

## VM Config

Create a VM-local config from the template:

```powershell
Copy-Item C:\vip-agent\repo\vip_config.example.json C:\vip-agent\vip_config.json
notepad C:\vip-agent\vip_config.json
```

Set these values per VM:

- `vnic_id`: that VM primary VNIC OCID.
- `secondary_ips`: the shared VIP addresses.
- `managed_vips[].private_ip_ocid`: the OCI private IP OCID for each VIP.
- `auth_mode`: usually `instance_principal` on OCI VMs.
- `windows.add_script`: usually `windows_vms\\add_ip.ps1`.
- `windows.remove_script`: usually `windows_vms\\remove_ip.ps1`.

## aux_vm Scripts

Show private IPs currently assigned to the configured VNIC:

```powershell
C:\vip-agent\aux_vm\add_vnic_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json -ShowAssigned
C:\vip-agent\aux_vm\remove_vnic_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json -ShowAssigned
```

Create or assign the configured secondary IPs to the configured VNIC in OCI:

```powershell
C:\vip-agent\aux_vm\add_vnic_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json
```

Starting fresh, create the secondary private IP resources and write a config in one run:

```powershell
C:\vip-agent\aux_vm\add_vnic_ip.ps1 -VnicId <active_vm_primary_vnic_ocid> -Ip 10.200.0.213,10.200.0.214 -Region ap-sydney-1 -AuthMode instance_principal -WriteConfig -WriteConfigPath C:\vip-agent\vip_config.json
```

Remove configured secondary IPs from the configured VNIC in OCI:

```powershell
C:\vip-agent\aux_vm\remove_vnic_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json
```

Move the configured OCI private IP resources to the current VM primary VNIC and bind them to the local Windows NIC:

```powershell
C:\vip-agent\aux_vm\startup_takeover.ps1 -ConfigPath C:\vip-agent\vip_config.json
```

Preview without changing OCI or Windows:

```powershell
C:\vip-agent\aux_vm\add_vnic_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json -DryRun
C:\vip-agent\aux_vm\remove_vnic_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json -DryRun
C:\vip-agent\aux_vm\startup_takeover.ps1 -ConfigPath C:\vip-agent\vip_config.json -DryRun
```

Move OCI private IP resources only and skip local Windows NIC bind:

```powershell
C:\vip-agent\aux_vm\startup_takeover.ps1 -ConfigPath C:\vip-agent\vip_config.json -SkipWindowsBind
```

`startup_takeover.ps1` uses `oci network vnic assign-private-ip --unassign-if-already-assigned`. That OCI operation moves the private IP resource from the old VNIC to the new VNIC. The script does not log in to the old VM to remove a stale Windows OS IP.

## windows_vms Scripts

Bind configured VIPs to the local Windows NIC only:

```powershell
C:\vip-agent\repo\windows_vms\add_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json
```

Remove configured VIPs from the local Windows NIC only:

```powershell
C:\vip-agent\repo\windows_vms\remove_ip.ps1 -ConfigPath C:\vip-agent\vip_config.json
```

Use these helpers when OCI ownership is already correct and you only need to repair the local Windows network configuration.

## OCI CLI Auth

The `aux_vm` scripts default to OCI instance principal auth. When `auth_mode` is `instance_principal`, the scripts create `~\.oci\config` if needed with:

```text
[DEFAULT]
auth=instance_principal
region=<region>
```

If OCI CLI is missing, the scripts try to install it with Python/pip and then retry the OCI call in the same run. Use `-NoInstallOciCli` to disable automatic install.

## Terraform Notes

The `terraform/` folder creates a Windows Server 2022 Standard VM in an existing compartment, VCN, and subnet. It does not inject an SSH key.

OCI Resource Manager uses `terraform/schema.yaml` to render LOV pickers for the target compartment, VCN, and subnet.

If `hostname_label` is blank, Terraform derives both the VNIC `hostname_label` and instance metadata `hostname` from `vm_display_name` by removing special characters. An explicit `hostname_label` overrides the derived value.

When `create_iam_resources` is true, Terraform creates a compartment policy that allows the selected dynamic group to `manage virtual-network-family` in the target compartment. By default `create_dynamic_group` is false, so provide `existing_dynamic_group_name`; only enable `create_dynamic_group` when the tenancy has Dynamic Group quota available.

For defined tags, use the Terraform OCI provider flat key format, for example:

```hcl
defined_tags = { "Operations.CostCenter" = "42" }
```
