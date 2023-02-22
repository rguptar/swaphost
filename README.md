# swaphost

Changing the nodepool SKU for an Azure Kubernetes Service cluster is a multi-step process.

This script automates it:
- Creates new nodepool in the same configuration as the old nodepool (apart from the SKU)
- Cordons + drains the nodes of the old nodepool
- Deletes the old nodepool

```
Usage: ./swaphost.sh -g <resource group> \
                     -n <cluster name> \
                     -m <mode> \
                     -p <priority> \
                     -s <new vm sku> \
                     -a <old nodepool> \
                     -b <new nodepool>
```

## Credits
semver2.sh: https://github.com/Ariel-Rodriguez/sh-semversion-2
