terraform {
  required_version = ">= 1.4.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

provider "oci" {
  region = var.region
  #auth   = var.oci_auth
  #config_file_path    = var.oci_config_file_path
  #config_file_profile = var.oci_config_file_profile
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  #fingerprint      = var.fingerprint
  #private_key_path = var.private_key_path
}

data "oci_identity_compartment" "target" {
  id = var.compartment_ocid
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid == null ? data.oci_identity_compartment.target.compartment_id : var.tenancy_ocid
}

data "oci_core_subnet" "target" {
  subnet_id = var.subnet_ocid
}

data "oci_core_images" "windows_2022_standard" {
  count = local.use_platform_image ? 1 : 0

  compartment_id           = var.tenancy_ocid
  operating_system         = var.windows_image_operating_system
  operating_system_version = var.windows_image_operating_system_version
  shape                    = var.vm_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  expected_vcn_ocid             = var.vcn_ocid == null ? "" : trimspace(var.vcn_ocid)
  use_platform_image            = var.image_ocid == "" || trimspace(var.image_ocid) == ""
  selected_image_ocid           = local.use_platform_image ? data.oci_core_images.windows_2022_standard[0].images[0].id : var.image_ocid
  use_shape_config              = length(regexall("\\.Flex$", var.vm_shape)) > 0
  primary_vnic_name             = var.primary_vnic_display_name == null ? "${var.vm_display_name}-vnic" : var.primary_vnic_display_name
  sanitized_display_name        = replace(lower(var.vm_display_name), "/[^a-z0-9-]/", "")
  hostname_label_seed           = local.sanitized_display_name == "" ? "vm" : local.sanitized_display_name
  derived_hostname              = substr(can(regex("^[a-z]", local.hostname_label_seed)) ? local.hostname_label_seed : "vm${local.hostname_label_seed}", 0, 15)
  explicit_hostname_label       = trimspace(var.hostname_label)
  final_hostname                = local.explicit_hostname_label != "" ? local.explicit_hostname_label : local.derived_hostname
  effective_private_ip          = var.private_ip == "" || trimspace(var.private_ip) == "" ? null : var.private_ip
  bootstrap_repo_url_ps         = replace(var.bootstrap_repo_url, "'", "''")
  bootstrap_repo_ref_ps         = replace(var.bootstrap_repo_ref, "'", "''")
  bootstrap_target_dir_ps       = replace(var.bootstrap_target_dir, "'", "''")
  bootstrap_install_git_ps      = var.bootstrap_install_git ? "$true" : "$false"
  effective_fault_domain        = var.fault_domain == "" || trimspace(var.fault_domain) == "" ? null : var.fault_domain
  effective_availability_domain = var.availability_domain == null ? data.oci_identity_availability_domains.ads.availability_domains[0].name : var.availability_domain
}

resource "oci_core_instance" "windows_vm" {
  availability_domain  = local.effective_availability_domain
  compartment_id       = var.compartment_ocid
  display_name         = var.vm_display_name
  shape                = var.vm_shape
  fault_domain         = local.effective_fault_domain
  preserve_boot_volume = var.preserve_boot_volume

  metadata = {
    hostname = local.final_hostname
    user_data = base64encode(templatefile("${path.module}/bootstrap.ps1.tmpl", {
      install_git  = local.bootstrap_install_git_ps
      install_root = local.bootstrap_target_dir_ps
      repo_ref     = local.bootstrap_repo_ref_ps
      repo_url     = local.bootstrap_repo_url_ps
    }))
  }

  dynamic "shape_config" {
    for_each = local.use_shape_config ? [1] : []

    content {
      ocpus                     = var.vm_ocpus
      memory_in_gbs             = var.vm_memory_in_gbs
      baseline_ocpu_utilization = var.vm_baseline_ocpu_utilization
    }
  }

  create_vnic_details {
    subnet_id              = var.subnet_ocid
    display_name           = local.primary_vnic_name
    assign_public_ip       = var.assign_public_ip
    hostname_label         = local.final_hostname
    private_ip             = local.effective_private_ip
    nsg_ids                = var.nsg_ids
    skip_source_dest_check = var.skip_source_dest_check
  }

  source_details {
    source_type             = "image"
    source_id               = local.selected_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
    boot_volume_vpus_per_gb = var.boot_volume_vpus_per_gb
  }

  agent_config {
    is_management_disabled = var.management_agent_disabled
    is_monitoring_disabled = var.monitoring_agent_disabled
  }

  availability_config {
    recovery_action = var.recovery_action
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = var.disable_legacy_imds_endpoints
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags

  lifecycle {
    precondition {
      condition     = local.expected_vcn_ocid == "" || data.oci_core_subnet.target.vcn_id == local.expected_vcn_ocid
      error_message = "subnet_ocid must belong to vcn_ocid when vcn_ocid is provided."
    }

    precondition {
      condition     = !local.use_shape_config || (var.vm_ocpus != null && var.vm_memory_in_gbs != null)
      error_message = "Flex shapes require vm_ocpus and vm_memory_in_gbs."
    }
  }
}

data "oci_core_vnic_attachments" "windows_vm" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.windows_vm.id
}

data "oci_core_vnic" "primary" {
  vnic_id = data.oci_core_vnic_attachments.windows_vm.vnic_attachments[0].vnic_id
}

output "instance_ocid" {
  description = "OCID of the Windows compute instance."
  value       = oci_core_instance.windows_vm.id
}

output "primary_vnic_ocid" {
  description = "OCID of the primary VNIC. Use this as vnic_id in vip_config.json on this VM."
  value       = data.oci_core_vnic.primary.id
}

output "primary_private_ip" {
  description = "Primary private IP assigned to the Windows VM."
  value       = data.oci_core_vnic.primary.private_ip_address
}

output "public_ip" {
  description = "Public IP assigned to the primary VNIC when assign_public_ip is true."
  value       = data.oci_core_vnic.primary.public_ip_address
}

output "image_ocid" {
  description = "Image OCID used for the Windows VM."
  value       = local.selected_image_ocid
}

output "derived_hostname" {
  description = "Hostname derived from vm_display_name, unless hostname_label overrides it."
  value       = local.final_hostname
}

output "hostname_label" {
  description = "Primary VNIC hostname_label derived from vm_display_name, unless hostname_label overrides it."
  value       = local.final_hostname
}

