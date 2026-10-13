#!/usr/bin/env bash
# =============================================================================
#  destroy/04-destroy-networking.sh — delete the network layer (az cli)
# =============================================================================
#  Azure refuses to delete a network object that something still uses, so the
#  order is the reverse of how they depend on each other:
#
#    1. application gateways        (use subnets + public IPs)
#    2. private endpoints           (use subnets)
#    3. load balancers              (use public IPs + subnets)
#    4. NAT gateways                (detach from subnets first; use public IPs)
#    5. public IP addresses         (now free)
#    6. private DNS zone links, private DNS zones, public DNS zones
#    7. subnets                     (detach NSG + route table first; fails if NICs/delegations remain)
#    8. network security groups, route tables
#    9. virtual networks
#
#  Only RESOURCE_GROUP is touched unless INCLUDE_NODE_RG=true. Failures are
#  reported and the script carries on, so run it again after removing whatever
#  still holds a dependency (usually: the cluster is not deleted yet).
#
#  Azure CLI commands used (list = read, delete = destroy):
#     az network application-gateway list/delete -g <rg> [-n <name>]
#     az network private-endpoint list/delete
#     az network lb list/delete
#     az network nat gateway list/delete
#     az network vnet subnet update ... --remove natGateway / networkSecurityGroup / routeTable   detach links
#     az network public-ip list/delete
#     az network private-dns link vnet list/delete -z <zone>
#     az network private-dns zone list/delete
#     az network dns zone list/delete
#     az network vnet subnet list/delete --vnet-name <vnet>
#     az network nsg list/delete
#     az network route-table list/delete
#     az network vnet list/delete
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check

hr
warn "This deletes ALL networking resources in $RESOURCE_GROUP$( [[ "$INCLUDE_NODE_RG" == "true" ]] && printf ' and %s' "$NODE_RESOURCE_GROUP")."
confirm "$CLUSTER_NAME"

# del <description> <az args...> : run a delete, warn but continue on failure
del() {
  local what="$1"; shift
  log "  delete $what"
  run az "$@" || warn "failed: $what (something still depends on it?)"
}

# names <az list args...> : names of all resources returned by an `az ... list`
names() { az "$@" --query '[].name' -o tsv 2>/dev/null || true; }

destroy_networking_in_rg() {
  local rg="$1" n v s
  if ! rg_exists "$rg"; then log "Resource group $rg does not exist — skipping"; return 0; fi

  hr; log "[$rg] 1/9 application gateways"
  for n in $(names network application-gateway list -g "$rg"); do
    del "application gateway $n" network application-gateway delete -g "$rg" -n "$n"
  done

  hr; log "[$rg] 2/9 private endpoints"
  for n in $(names network private-endpoint list -g "$rg"); do
    del "private endpoint $n" network private-endpoint delete -g "$rg" -n "$n"
  done

  hr; log "[$rg] 3/9 load balancers"
  for n in $(names network lb list -g "$rg"); do
    del "load balancer $n" network lb delete -g "$rg" -n "$n"
  done

  hr; log "[$rg] 4/9 NAT gateways (detach from subnets first)"
  for v in $(names network vnet list -g "$rg"); do
    while IFS='|' read -r s nat; do
      [[ -z "$s" || -z "$nat" ]] && continue
      log "  detach NAT gateway from subnet $v/$s"
      run az network vnet subnet update -g "$rg" --vnet-name "$v" -n "$s" --remove natGateway -o none || warn "could not detach NAT gateway from $v/$s"
    done < <(az network vnet subnet list -g "$rg" --vnet-name "$v" -o json | jq -r '.[] | [.name, (.natGateway.id // "")] | join("|")')
  done
  for n in $(names network nat gateway list -g "$rg"); do
    del "NAT gateway $n" network nat gateway delete -g "$rg" -n "$n"
  done

  hr; log "[$rg] 5/9 public IP addresses"
  for n in $(names network public-ip list -g "$rg"); do
    del "public IP $n" network public-ip delete -g "$rg" -n "$n"
  done

  hr; log "[$rg] 6/9 DNS zones"
  for n in $(names network private-dns zone list -g "$rg"); do
    local l
    for l in $(names network private-dns link vnet list -g "$rg" -z "$n"); do
      del "private DNS link $n/$l" network private-dns link vnet delete -g "$rg" -z "$n" -n "$l" --yes
    done
    del "private DNS zone $n" network private-dns zone delete -g "$rg" -n "$n" --yes
  done
  for n in $(names network dns zone list -g "$rg"); do
    del "DNS zone $n" network dns zone delete -g "$rg" -n "$n" --yes
  done

  hr; log "[$rg] 7/9 subnets (detach NSG / route table first)"
  for v in $(names network vnet list -g "$rg"); do
    while IFS='|' read -r s nsg rt inuse; do
      [[ -z "$s" ]] && continue
      if [[ -n "$nsg" ]]; then
        run az network vnet subnet update -g "$rg" --vnet-name "$v" -n "$s" --remove networkSecurityGroup -o none || warn "could not detach NSG from $v/$s"
      fi
      if [[ -n "$rt" ]]; then
        run az network vnet subnet update -g "$rg" --vnet-name "$v" -n "$s" --remove routeTable -o none || warn "could not detach route table from $v/$s"
      fi
      if [[ "$inuse" != "0" ]]; then
        warn "  subnet $v/$s still has $inuse IP configuration(s) (VMSS nodes? private endpoints?) — deletion will fail until they are gone"
      fi
      del "subnet $v/$s" network vnet subnet delete -g "$rg" --vnet-name "$v" -n "$s"
    done < <(az network vnet subnet list -g "$rg" --vnet-name "$v" -o json \
             | jq -r '.[] | [.name, (.networkSecurityGroup.id // ""), (.routeTable.id // ""), ((.ipConfigurations // []) | length | tostring)] | join("|")')
  done

  hr; log "[$rg] 8/9 network security groups and route tables"
  for n in $(names network nsg list -g "$rg"); do
    del "NSG $n" network nsg delete -g "$rg" -n "$n"
  done
  for n in $(names network route-table list -g "$rg"); do
    del "route table $n" network route-table delete -g "$rg" -n "$n"
  done

  hr; log "[$rg] 9/9 virtual networks"
  for v in $(names network vnet list -g "$rg"); do
    del "VNet $v" network vnet delete -g "$rg" -n "$v"
  done
}

destroy_networking_in_rg "$RESOURCE_GROUP"
if [[ "$INCLUDE_NODE_RG" == "true" && -n "$NODE_RESOURCE_GROUP" ]]; then
  destroy_networking_in_rg "$NODE_RESOURCE_GROUP"
fi

hr
ok "Networking clean-up finished. Next: ./destroy/05-destroy-platform-services.sh"
