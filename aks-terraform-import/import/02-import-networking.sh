#!/usr/bin/env bash
# =============================================================================
#  import/02-import-networking.sh — Virtual network layer
# =============================================================================
#  Records import blocks for every networking object in RESOURCE_GROUP:
#
#   Azure object                     Terraform resource type                          Import ID
#   ------------------------------   ----------------------------------------------   ----------------------------
#   Virtual network                  azurerm_virtual_network                          VNet ARM ID
#   Subnet                           azurerm_subnet                                   subnet ARM ID
#   Subnet <-> NSG link              azurerm_subnet_network_security_group_association subnet ARM ID
#   Subnet <-> route table link      azurerm_subnet_route_table_association           subnet ARM ID
#   Subnet <-> NAT gateway link      azurerm_subnet_nat_gateway_association           subnet ARM ID
#   Network security group           azurerm_network_security_group                   NSG ARM ID (rules inline)
#   Route table                      azurerm_route_table                              route table ARM ID (routes inline)
#   Public IP address                azurerm_public_ip                                public IP ARM ID
#   Load balancer                    azurerm_lb                                       LB ARM ID
#   NAT gateway                      azurerm_nat_gateway                              NAT gateway ARM ID
#   NAT gateway <-> public IP link   azurerm_nat_gateway_public_ip_association        "<natgw id>|<public ip id>"
#   Private DNS zone                 azurerm_private_dns_zone                         zone ARM ID
#   Private DNS zone <-> VNet link   azurerm_private_dns_zone_virtual_network_link    link ARM ID
#   Public DNS zone                  azurerm_dns_zone                                 zone ARM ID
#   Private endpoint                 azurerm_private_endpoint                         private endpoint ARM ID
#   Application gateway              azurerm_application_gateway                      app gateway ARM ID
#
#  The AKS NODE resource group (MC_*) also contains networking objects — the
#  "kubernetes" load balancer, outbound public IPs, the agent-pool NSG and
#  route table, the private-cluster private endpoint. AKS creates and keeps
#  reconciling them. They are only scanned when INCLUDE_NODE_RG=true; leave
#  that false unless you have a specific reason (see README).
#
#  Azure CLI commands used (all read-only, all "-o json"):
#     az network vnet list -g <rg>                              VNets
#     az network vnet subnet list -g <rg> --vnet-name <vnet>    subnets + their NSG / route table / NAT gw links
#     az network nsg list -g <rg>                               network security groups
#     az network route-table list -g <rg>                       route tables
#     az network public-ip list -g <rg>                         public IPs
#     az network lb list -g <rg>                                load balancers
#     az network nat gateway list -g <rg>                       NAT gateways (+ attached public IPs)
#     az network private-dns zone list -g <rg>                  private DNS zones
#     az network private-dns link vnet list -g <rg> -z <zone>   zone-to-VNet links
#     az network dns zone list -g <rg>                          public DNS zones
#     az network private-endpoint list -g <rg>                  private endpoints
#     az network application-gateway list -g <rg>              application gateways
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin networking

# import_networking_in_rg <resource group>
import_networking_in_rg() {
  local rg="$1"
  local json name id
  hr
  log "Scanning networking in resource group: $rg"

  # --- Virtual networks, subnets and the three subnet association resources --
  json="$(az network vnet list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_virtual_network "$(tf_name "$name")" "$id" "VNet $name"

    local subnets sname sid nsg rt nat
    subnets="$(az network vnet subnet list -g "$rg" --vnet-name "$name" -o json)"
    while IFS='|' read -r sname sid nsg rt nat; do
      [[ -z "$sname" ]] && continue
      tf_import_add azurerm_subnet "$(tf_name "${name}_${sname}")" "$sid" "Subnet $name/$sname"
      # Associations are separate Terraform resources whose import ID is the SUBNET id.
      if [[ -n "$nsg" ]]; then
        tf_import_add azurerm_subnet_network_security_group_association "$(tf_name "${name}_${sname}_nsg")" "$sid" "Subnet $sname -> NSG ${nsg##*/}"
      fi
      if [[ -n "$rt" ]]; then
        tf_import_add azurerm_subnet_route_table_association "$(tf_name "${name}_${sname}_rt")" "$sid" "Subnet $sname -> route table ${rt##*/}"
      fi
      if [[ -n "$nat" ]]; then
        tf_import_add azurerm_subnet_nat_gateway_association "$(tf_name "${name}_${sname}_nat")" "$sid" "Subnet $sname -> NAT gateway ${nat##*/}"
      fi
    done < <(jq -r '.[] | [.name, .id, (.networkSecurityGroup.id // ""), (.routeTable.id // ""), (.natGateway.id // "")] | join("|")' <<<"$subnets")
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- Network security groups (security rules are generated inline) --------
  json="$(az network nsg list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_network_security_group "$(tf_name "$name")" "$id" "NSG $name"
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- Route tables (routes are generated inline) ----------------------------
  json="$(az network route-table list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_route_table "$(tf_name "$name")" "$id" "Route table $name"
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- Public IP addresses --------------------------------------------------
  json="$(az network public-ip list -g "$rg" -o json)"
  while IFS='|' read -r name id addr; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_public_ip "$(tf_name "$name")" "$id" "Public IP $name ($addr)"
  done < <(jq -r '.[] | [.name, .id, (.ipAddress // "unallocated")] | join("|")' <<<"$json")

  # --- Load balancers --------------------------------------------------------
  json="$(az network lb list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_lb "$(tf_name "$name")" "$id" "Load balancer $name"
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- NAT gateways + their public IP associations ---------------------------
  json="$(az network nat gateway list -g "$rg" -o json)"
  while IFS='|' read -r name id pips; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_nat_gateway "$(tf_name "$name")" "$id" "NAT gateway $name"
    local pip
    for pip in $pips; do   # space separated list of public IP ids
      tf_import_add azurerm_nat_gateway_public_ip_association "$(tf_name "${name}_${pip##*/}")" "${id}|${pip}" "NAT gateway $name -> public IP ${pip##*/}"
    done
  done < <(jq -r '.[] | [.name, .id, ([.publicIpAddresses[]?.id] | join(" "))] | join("|")' <<<"$json")

  # --- Private DNS zones + VNet links ----------------------------------------
  json="$(az network private-dns zone list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_private_dns_zone "$(tf_name "$name")" "$id" "Private DNS zone $name"
    local links lname lid
    links="$(az network private-dns link vnet list -g "$rg" -z "$name" -o json)"
    while IFS='|' read -r lname lid; do
      [[ -z "$lname" ]] && continue
      tf_import_add azurerm_private_dns_zone_virtual_network_link "$(tf_name "${name}_${lname}")" "$lid" "Private DNS link $name/$lname"
    done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$links")
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- Public DNS zones ------------------------------------------------------
  json="$(az network dns zone list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_dns_zone "$(tf_name "$name")" "$id" "DNS zone $name"
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- Private endpoints -----------------------------------------------------
  json="$(az network private-endpoint list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_private_endpoint "$(tf_name "$name")" "$id" "Private endpoint $name"
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

  # --- Application gateways (e.g. AGIC ingress) ------------------------------
  json="$(az network application-gateway list -g "$rg" -o json)"
  while IFS='|' read -r name id; do
    [[ -z "$name" ]] && continue
    tf_import_add azurerm_application_gateway "$(tf_name "$name")" "$id" "Application gateway $name"
  done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")
}

import_networking_in_rg "$RESOURCE_GROUP"

if [[ "$INCLUDE_NODE_RG" == "true" ]] && rg_exists "$NODE_RESOURCE_GROUP"; then
  warn "INCLUDE_NODE_RG=true: importing AKS-managed networking from $NODE_RESOURCE_GROUP."
  warn "Expect permanent plan drift on these; destroy them via the cluster, not individually."
  import_networking_in_rg "$NODE_RESOURCE_GROUP"
fi

tf_import_end
