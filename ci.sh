echo "ci"
az login --service-principal -u $AZURE_USER -p $AZURE_PASSWORD --tenant $AZURE_TENANT --output none
./swaphost.sh -g aks -n k8s -m System -p Regular -s Standard_D2s_v3 -a system -b sys