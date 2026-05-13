locals {
  iam_name_prefix              = substr(replace(lower(var.vm_display_name), "/[^a-z0-9_]/", "-"), 0, 48)
  existing_dynamic_group_name  = trimspace(var.existing_dynamic_group_name)
  should_create_dynamic_group  = var.create_iam_resources && var.create_dynamic_group
  effective_dynamic_group_name = local.should_create_dynamic_group ? oci_identity_dynamic_group.windows_vm[0].name : local.existing_dynamic_group_name
}

resource "oci_identity_dynamic_group" "windows_vm" {
  count = local.should_create_dynamic_group ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${local.iam_name_prefix}-dg"
  description    = "Dynamic group for the Windows VIP failover instance."

  matching_rule = "ALL {instance.id = '${oci_core_instance.windows_vm.id}'}"
}

resource "oci_identity_policy" "windows_vm_virtual_network" {
  count = var.create_iam_resources ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = "${local.iam_name_prefix}-vcn-policy"
  description    = "Allow the Windows VIP failover instance to manage virtual networking in this compartment."

  statements = [
    "Allow dynamic-group ${local.effective_dynamic_group_name} to manage virtual-network-family in compartment id ${var.compartment_ocid}",
  ]

  lifecycle {
    precondition {
      condition     = local.effective_dynamic_group_name != ""
      error_message = "Set existing_dynamic_group_name when create_iam_resources is true and create_dynamic_group is false, or set create_dynamic_group to true if tenancy quota allows it."
    }
  }
}

output "dynamic_group_ocid" {
  description = "OCID of the dynamic group created for the Windows VM. Null when no dynamic group is created by this stack."
  value       = local.should_create_dynamic_group ? oci_identity_dynamic_group.windows_vm[0].id : null
}

output "dynamic_group_name" {
  description = "Dynamic group name used by the IAM policy. This can be a newly created group or an existing group."
  value       = var.create_iam_resources ? local.effective_dynamic_group_name : null
}

output "created_dynamic_group_matching_rule" {
  description = "Matching rule for the dynamic group created by this stack. Null when using an existing dynamic group."
  value       = local.should_create_dynamic_group ? oci_identity_dynamic_group.windows_vm[0].matching_rule : null
}

output "virtual_network_policy_ocid" {
  description = "OCID of the compartment policy granting virtual-network-family permissions. Null when create_iam_resources is false."
  value       = var.create_iam_resources ? oci_identity_policy.windows_vm_virtual_network[0].id : null
}
