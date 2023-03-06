#!/bin/bash

source ./semver2.sh

function usage {
    echo "Usage: $0 -g <resource group> -n <cluster name> -m <mode> [-p <priority>] -s <new vm sku> -a <old nodepool> -b <new nodepool> [-f]"
    echo "  -g <resource group>     resource group of the cluster"
    echo "  -n <cluster name>       name of the cluster"
    echo "  -m <mode>               mode of the new nodepool; must match the old nodepool {System, User}"
    echo "  -p <priority>           priority of the new nodepool {Regular, Spot}"
    echo "  -s <new vm sku>         new vm sku"
    echo "  -a <old nodepool>       name of the old nodepool"
    echo "  -b <new nodepool>       name of the new nodepool"
    echo "  -f                      skip validation"
    exit
}

function get_json_array() {
    echo "$1" | jq -rc "$2"
}

function get_json_value() {
    echo "$1" | jq -r "$2"
}

rg=
cluster=
oldNodepool=
newNodepool=
newVmSku=
mode=
priority=Regular
skipValidation=0
args=$(getopt hfa:b:g:m:n:p:s: $*)
set -- $args
for i; do
    case "$i" in
    -h)
        usage
        exit
        ;;
    -f)
        skipValidation=1
        ;;
    -g)
        rg=$2
        shift
        shift
        ;;
    -n)
        cluster=$2
        shift
        shift
        ;;
    -a)
        oldNodepool=$2
        shift
        shift
        ;;
    -b)
        newNodepool=$2
        shift
        shift
        ;;
    -s)
        newVmSku=$2
        shift
        shift
        ;;
    -m)
        mode=$2
        shift
        shift
        ;;
    -p)
        priority=$2
        shift
        shift
        ;;
    --)
        shift
        break
        ;;
    esac
done

if [ -z "$rg" ] || [ -z "$cluster" ] || [ -z "$mode" ] || [ -z "$newVmSku" ] || [ -z "$oldNodepool" ] || [ -z "$newNodepool" ]; then
    usage
fi

check="\xE2\x9C\x94"
cross="\xE2\x9C\x98"
function valid() {
    echo -e "$check $1"
}
function invalid() {
    echo -e "$cross $1"
    exit
}

if [ $skipValidation -eq 0 ]; then
    if [ "$mode" != "System" ] && [ "$mode" != "User" ]; then
        invalid "invalid mode $mode"
    fi
    valid "valid mode $mode"

    if [ "$priority" != "Regular" ] && [ "$priority" != "Spot" ]; then
        invalid "invalid priority $priority"
    fi
    if [ "$mode" == "System" ] && [ "$priority" == "Spot" ]; then
        invalid "invalid mode, priority combination $mode, $priority"
    fi
    valid "valid priority $priority"

    oldNodepoolExists=0
    oldNodepoolMode=
    nodepools=$(az aks show -g $rg -n $cluster | jq '.agentPoolProfiles[] | {name: .name, mode: .mode}' | jq -s)
    for nodepool in $(get_json_array "$nodepools" ".[]"); do
        name=$(echo $(get_json_array "$nodepool" ".name"))
        if [ "$name" == "$oldNodepool" ]; then
            oldNodepoolExists=1
            oldNodepoolMode=$(echo $(get_json_array "$nodepool" ".mode"))
            valid "old nodepool exists"
        fi
        if [ "$name" == "$newNodepool" ]; then
            invalid "new nodepool exists"
        fi
    done
    if [ $oldNodepoolExists -eq 0 ]; then
        invalid "old nodepool does not exist"
    fi
    valid "new nodepool does not exist"
    # todo: add support for same name

    if [ "$oldNodepoolMode" != "$mode" ]; then
        invalid "old nodepool mode $oldNodepoolMode does not match new nodepool mode $mode"
    fi
    valid "modes match"

    aksLocation=$(az aks show -g $rg -n $cluster --query location -o tsv)
    skuExists=$(az vm list-sizes --location $aksLocation --query "[].name" | jq -r "index(\"$newVmSku\")")
    if [ "$skuExists" == "null" ]; then
        invalid "the specified sku $newVmSku does not exist in location $aksLocation"
    fi
    valid "sku valid"

    clusterVersion=$(az aks show -g $rg -n $cluster --query kubernetesVersion -o tsv)
    comparison=$(semver_compare "$clusterVersion" "1.21")
    if [ $comparison -lt 0 ]; then
        invalid "pod disruption budget is not available for k8s versions older than 1.21; cluster $cluster runs on $clusterVersion"
    fi
    valid "pdb supported"

    # todo: filter pdb by workloads running on the specified old nodepool
    az aks get-credentials -g $rg -n $cluster
    pdbs=$(kubectl get pdb -A -o json | jq)
    for pdb in $(get_json_array "$pdbs" ".items[]"); do
        name=$(get_json_value "$pdb" '.metadata.name')
        disruptionsAllowed=$(get_json_value "$pdb" '.status.disruptionsAllowed')
        if [ "$disruptionsAllowed" -lt 1 ]; then
            invalid "pdb is not sufficient for evicting pods: $name; try again later"
        fi
    done
    valid "pdb found"
fi

sub=$(az account show --query id -o tsv)
az group export \
    --name $rg \
    --resource-ids /subscriptions/$sub/resourcegroups/$rg/providers/Microsoft.ContainerService/managedClusters/$cluster \
    --skip-all-params | jq ".resources[] | select(.name == \"$cluster/$oldNodepool\")" | jq 'del(.dependsOn)' > nodepool.json
tmp=$(mktemp)
jq ".properties.vmSize = \"$newVmSku\"" nodepool.json > $tmp
jq ".name = \"$newNodepool\"" $tmp > nodepool.json && rm $tmp
tee nodepool.template.json > /dev/null <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {},
  "resources": [
    $(cat nodepool.json)
  ]
}
EOF
az deployment group create -g $rg  --template-file ./nodepool.template.json

oldNodes=$(kubectl get nodes -o json | jq ".items[] | select(.metadata.labels.agentpool==\"$oldNodepool\") | {agentpool: .metadata.labels.agentpool, name: .metadata.name}" | jq -s)
echo "starting cordon + drain"
for node in $(get_json_array "$oldNodes" ".[]"); do
    name=$(echo $(get_json_array "$node" ".name"))
    kubectl cordon $name
    kubectl drain $name --ignore-daemonsets --delete-emptydir-data
    valid "managedClusters/$cluster/agentPools/$newNodepool/node/$name"
done

echo "deleting old nodepool"
az aks nodepool delete --cluster-name $cluster -n $oldNodepool -g $rg

valid "swaphost complete"
