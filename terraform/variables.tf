variable "region" {
  description = "OCI region, for example ap-sydney-1."
  type        = string
}

variable "oci_auth" {
  description = "Optional OCI provider auth mode. Leave null for normal config/env behavior, or use values such as APIKey, InstancePrincipal, ResourcePrincipal, or SecurityToken."
  type        = string
  default     = null
}

variable "oci_config_file_path" {
  description = "Optional OCI config file path for the Terraform provider."
  type        = string
  default     = null
}

variable "oci_config_file_profile" {
  description = "Optional OCI config profile name for the Terraform provider."
  type        = string
  default     = null
}

variable "tenancy_ocid" {
  description = "Optional tenancy OCID for API key auth. Not used as an SSH key."
  type        = string
  default     = null
}

variable "user_ocid" {
  description = "Optional user OCID for API key auth."
  type        = string
  default     = null
}

variable "fingerprint" {
  description = "Optional API key fingerprint for API key auth."
  type        = string
  default     = null
}

variable "private_key_path" {
  description = "Optional OCI API private key path for Terraform provider auth. This is not a VM SSH key."
  type        = string
  default     = null
}

variable "compartment_ocid" {
  description = "Compartment OCID where the Windows VM will be created."
  type        = string
}

variable "vcn_ocid" {
  description = "VCN OCID expected to contain subnet_ocid. Optional but recommended as a guardrail."
  type        = string
  default     = null
}

variable "subnet_ocid" {
  description = "Subnet OCID where the Windows VM primary VNIC will be attached."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name for the VM, for example abcD:AP-SYDNEY-1-AD-1."
  type        = string
  default     = null
}

variable "vm_display_name" {
  description = "Display name for the Windows VM."
  type        = string
  default     = "vip-windows-2022"
}

variable "vm_shape" {
  description = "OCI compute shape for the VM. Flex shapes use vm_ocpus and vm_memory_in_gbs."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "vm_ocpus" {
  description = "OCPU count for Flex shapes. Ignored for fixed shapes."
  type        = number
  default     = 2

  validation {
    condition     = var.vm_ocpus == null || var.vm_ocpus > 0
    error_message = "vm_ocpus must be greater than 0 when set."
  }
}

variable "vm_memory_in_gbs" {
  description = "Memory in GB for Flex shapes. Ignored for fixed shapes."
  type        = number
  default     = 16

  validation {
    condition     = var.vm_memory_in_gbs == null || var.vm_memory_in_gbs > 0
    error_message = "vm_memory_in_gbs must be greater than 0 when set."
  }
}

variable "vm_baseline_ocpu_utilization" {
  description = "Optional baseline OCPU utilization for burstable Flex shapes, for example BASELINE_1_1 or BASELINE_1_2."
  type        = string
  default     = null
}

variable "windows_image_operating_system" {
  description = "Operating system filter for OCI platform image lookup."
  type        = string
  default     = "Windows"
}

variable "windows_image_operating_system_version" {
  description = "Operating system version filter for OCI platform image lookup."
  type        = string
  default     = "Server 2022 Standard"
}

variable "windows_license_type" {
  description = "Windows Server license type for the instance. OCI_PROVIDED uses OCI-provided metered Windows licensing; BRING_YOUR_OWN_LICENSE requires eligible Microsoft BYOL rights."
  type        = string
  default     = "OCI_PROVIDED"

  validation {
    condition     = contains(["OCI_PROVIDED", "BRING_YOUR_OWN_LICENSE"], var.windows_license_type)
    error_message = "windows_license_type must be OCI_PROVIDED or BRING_YOUR_OWN_LICENSE."
  }
}

variable "image_ocid" {
  description = "Optional explicit image OCID. Leave empty to use the latest Windows Server 2022 Standard platform image matching vm_shape."
  type        = string
  default     = ""
}

variable "boot_volume_size_gbs" {
  description = "Boot volume size in GB. Windows platform images normally require a larger boot volume than Linux images."
  type        = number
  default     = 256

  validation {
    condition     = var.boot_volume_size_gbs >= 256
    error_message = "boot_volume_size_gbs should be at least 256 for Windows Server images."
  }
}

variable "boot_volume_vpus_per_gb" {
  description = "Boot volume performance in VPUs per GB."
  type        = number
  default     = 10

  validation {
    condition     = var.boot_volume_vpus_per_gb >= 0
    error_message = "boot_volume_vpus_per_gb must be zero or greater."
  }
}

variable "primary_vnic_display_name" {
  description = "Optional display name for the primary VNIC."
  type        = string
  default     = null
}

variable "assign_public_ip" {
  description = "Whether OCI should assign a public IP to the primary VNIC."
  type        = bool
  default     = false
}

variable "hostname_label" {
  description = "Optional DNS hostname label override for the primary VNIC. Leave empty to derive it from vm_display_name after removing special characters."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = can(regex("^(|[A-Za-z][A-Za-z0-9-]{0,14})$", var.hostname_label))
    error_message = "hostname_label must be empty or start with a letter, contain only letters, numbers, or hyphens, and be 15 characters or less."
  }
}

variable "private_ip" {
  description = "Optional fixed primary private IP for the VM. Leave empty for automatic assignment."
  type        = string
  default     = ""

  validation {
    condition     = var.private_ip == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.private_ip))
    error_message = "private_ip must look like an IPv4 address."
  }
}

variable "bootstrap_repo_url" {
  description = "Git repository URL cloned on first boot to populate C:\\vip-agent\\aux_vm. Do not include credentials in this URL."
  type        = string
  default     = "https://github.com/aszynkow/oci_vip_failover"

  validation {
    condition     = length(trimspace(var.bootstrap_repo_url)) > 0
    error_message = "bootstrap_repo_url must not be empty."
  }
}

variable "bootstrap_repo_ref" {
  description = "Git branch, tag, or commit checked out by the first-boot bootstrap script. Prefer a tag or commit for repeatable builds."
  type        = string
  default     = "main"

  validation {
    condition     = length(trimspace(var.bootstrap_repo_ref)) > 0
    error_message = "bootstrap_repo_ref must not be empty."
  }
}

variable "bootstrap_target_dir" {
  description = "Target installation directory on the Windows VM. aux_vm files are copied to bootstrap_target_dir\\aux_vm."
  type        = string
  default     = "C:\\vip-agent"

  validation {
    condition     = length(trimspace(var.bootstrap_target_dir)) > 0
    error_message = "bootstrap_target_dir must not be empty."
  }
}

variable "bootstrap_install_git" {
  description = "Install Git for Windows during first boot when git.exe is not already present."
  type        = bool
  default     = true
}

variable "nsg_ids" {
  description = "Network security group OCIDs to attach to the primary VNIC."
  type        = list(string)
  default     = []
}

variable "skip_source_dest_check" {
  description = "Whether to skip source/destination check on the primary VNIC. Usually false for Windows VIP hosts."
  type        = bool
  default     = false
}

variable "fault_domain" {
  description = "Optional fault domain, for example FAULT-DOMAIN-1."
  type        = string
  default     = ""
}

variable "preserve_boot_volume" {
  description = "Whether to preserve the boot volume when the instance is destroyed."
  type        = bool
  default     = false
}

variable "management_agent_disabled" {
  description = "Disable the OCI management agent on the VM."
  type        = bool
  default     = false
}

variable "monitoring_agent_disabled" {
  description = "Disable the OCI monitoring agent on the VM."
  type        = bool
  default     = false
}

variable "recovery_action" {
  description = "Instance recovery action, usually RESTORE_INSTANCE or STOP_INSTANCE."
  type        = string
  default     = "RESTORE_INSTANCE"

  validation {
    condition     = contains(["RESTORE_INSTANCE", "STOP_INSTANCE"], var.recovery_action)
    error_message = "recovery_action must be RESTORE_INSTANCE or STOP_INSTANCE."
  }
}

variable "disable_legacy_imds_endpoints" {
  description = "Disable legacy IMDS v1 endpoints. Keep true unless old tooling requires IMDS v1."
  type        = bool
  default     = true
}


variable "create_iam_resources" {
  description = "Create a target-compartment policy granting manage virtual-network-family to the selected dynamic group."
  type        = bool
  default     = true
}

variable "create_dynamic_group" {
  description = "Create a new dynamic group for this Windows instance. Leave false when tenancy dynamic group quota is exhausted and use existing_dynamic_group_name instead."
  type        = bool
  default     = false
}

variable "existing_dynamic_group_name" {
  description = "Existing dynamic group name to use for the IAM policy when create_dynamic_group is false. The group matching rule must include this Windows instance."
  type        = string
  default     = ""
  nullable    = false
}

variable "defined_tags" {
  description = "Defined tags to apply to the instance. Use flat Terraform OCI keys such as Operations.CostCenter = 42."
  type        = map(string)
  default     = {}
}

variable "freeform_tags" {
  description = "Freeform tags to apply to the instance."
  type        = map(string)
  default = {
    role = "vip-failover"
  }
}
