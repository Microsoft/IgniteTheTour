echo ""
echo "Welcome to Tailwind Traders Data Migration!!"
echo ""
echo "******"
echo "- Use the Subscription ID for Subscription."
echo "- Get list of available Azure Regions using 'az account list-locations' - use the 'name' property."
echo "- You can use an existing Resource Group if you like."
echo "******"
echo ""

if [ -d "original" ]
then
    echo "Restoring original scripts and configs"
    cp original/* .
else
    echo "Backing up original scripts and configs"
    mkdir original
    cp *.sh original
    cp *.json original
fi

echo ""

read -p 'Subscription to use: ' SUBSCRIPTION
read -p 'Azure Region name to use: ' AZURE_REGION
read -p 'Unique prefix (applied to all resources): ' RESOURCE_PREFIX
read -p 'Username (applied to all resources): ' USERNAME
read -sp 'Password (applied to all resources - no exclamation points): ' PASSWORD


REGISTRY_NAME="$RESOURCE_PREFIX"registry
RESOURCE_GROUP_NAME="$RESOURCE_PREFIX"-datamig-demo
PRODUCT_SERVICE_NAME="$RESOURCE_PREFIX"product
INVENTORY_SERVICE_NAME="$RESOURCE_PREFIX"inventory
INVENTORY_SERVICE_VM_NAME="$INVENTORY_SERVICE_NAME"vm
FRONTEND_NAME="$RESOURCE_PREFIX"frontend
COSMOSDB_NAME="$RESOURCE_PREFIX"cosmosdb
SQL_MI_NAME="$RESOURCE_PREFIX"sqlmi
SQL_MI_VNET_NAME="$RESOURCE_PREFIX"sqlmivnet
SQL_MI_SUBNET_NAME=subnet1
SQL_DMS_NAME="$RESOURCE_PREFIX"dms
SQL2012_VM_NAME='sql2012'
MONGO_VM_NAME='mongo'

PRODUCT_SERVICE_IMAGE='tailwind-product-service:0.1'
INVENTORY_SERVICE_IMAGE='tailwind-inventory-service:0.1'
FRONTEND_IMAGE='tailwind-frontend:0.1'

MAIN_REGION="$AZURE_REGION"

printf "\n*** Setting the subsription to $SUBSCRIPTION***\n"
az account set --subscription "$SUBSCRIPTION"

printf "\n*** Creating resource group $RESOURCE_GROUP_NAME ***\n"
az group create -n $RESOURCE_GROUP_NAME -l $MAIN_REGION

printf "\n*** Creating the SQL Server 2012 Virtual Machine (can take 20 minutes) ***\n"
az group deployment create -g $RESOURCE_GROUP_NAME --template-file sqlvmdeploy.json \
    --parameters adminUsername=$USERNAME adminPassword=$PASSWORD sqlAuthenticationPassword=$PASSWORD sqlAuthenticationLogin=$USERNAME virtualMachineName=$SQL2012_VM_NAME

SQL2012_VM_IP_ADDRESS=$(az vm list-ip-addresses -g $RESOURCE_GROUP_NAME -n $SQL2012_VM_NAME | jq -r '.[0].virtualMachine.network.publicIpAddresses[0].ipAddress')

printf "\n*** Creating the MongoDB Virtual Machine ***\n"

sed -i -e "s/REPLACEDROPUSERNAME/${USERNAME}/g" mongoconfigure.sh
sed -i -e "s/REPLACECREATEUSERNAME/${USERNAME}/g" mongoconfigure.sh
sed -i -e "s/REPLACEPASSWORD/${PASSWORD}/g" mongoconfigure.sh

az vm create --resource-group $RESOURCE_GROUP_NAME --name $MONGO_VM_NAME \
    --size Standard_D2s_v3 --image UbuntuLTS --custom-data mongocloudinit.sh \
    --admin-username azureuser --generate-ssh-keys

az vm user update -u azureuser --ssh-key-value "$(< ~/.ssh/id_rsa.pub)" -g $RESOURCE_GROUP_NAME -n $MONGO_VM_NAME

MONGO_IP_ADDRESS=$(az vm list-ip-addresses -g $RESOURCE_GROUP_NAME -n $MONGO_VM_NAME | jq -r '.[0].virtualMachine.network.publicIpAddresses[0].ipAddress')

sed -i -e "s/MONGO_IP_ADDRESS/${MONGO_IP_ADDRESS}/g" postprocess.sh

printf "\n*** Creating the necessary Mongo VM NSGs ***\n"
az network nsg rule create -n MongoDB --nsg-name "${MONGO_VM_NAME}NSG" -g $RESOURCE_GROUP_NAME --access Allow --direction Inbound --priority 500 --source-address-prefixes AzureCloud --destination-port-ranges 27017

printf "\n*** Cloning into DEV10: Designing Resilient Cloud Applications repository ***\n"
git clone https://github.com/microsoft/IgniteTheTour.git

printf "\n*** Deploying the App Services and Cosmos DB ***\n"

az group deployment create -g $RESOURCE_GROUP_NAME --template-file appservicedeploy.json --parameters prefix=$RESOURCE_PREFIX location=$MAIN_REGION sqlVMIPAddress=$SQL2012_VM_IP_ADDRESS sqlAdminLogin=$USERNAME sqlAdminPassword=$PASSWORD

cd "IgniteTheTour/DEV - Building your Applications for the Cloud/DEV10/deployment"

printf "\n*** Building Product Service image in ACR ***\n"
az acr build -t $PRODUCT_SERVICE_IMAGE -r $REGISTRY_NAME ../src/product-service

printf "\n*** Building Inventory Service image in ACR ***\n"
az acr build -t $INVENTORY_SERVICE_IMAGE -r $REGISTRY_NAME ../src/inventory-service/InventoryService.Api

printf "\n\n*** Building Frontend image in ACR ***\n"
az acr build -t $FRONTEND_IMAGE -r $REGISTRY_NAME ../src/frontend


printf "\n\n*** Retrieving ACR information ***\n"
ACR_SERVER=$(az acr show -n $REGISTRY_NAME --query loginServer -o tsv)
ACR_USERNAME=$(az acr credential show -n $REGISTRY_NAME --query username -o tsv)
ACR_PASSWORD=$(az acr credential show -n $REGISTRY_NAME --query passwords[0].value -o tsv)
printf "\n\n*** $ACR_SERVER $ACR_USERNAME ***\n"


#printf "\n\n*** Configuring Inventory Service to use ACR image ***\n"
#az webapp config container set -n $INVENTORY_SERVICE_NAME -g $RESOURCE_GROUP_NAME -i "$ACR_SERVER/$INVENTORY_SERVICE_IMAGE" -u $ACR_USERNAME -p $ACR_PASSWORD

printf "\n\n*** Configuring Product Service to use ACR image ***\n"
az webapp config container set -n $PRODUCT_SERVICE_NAME -g $RESOURCE_GROUP_NAME -i "$ACR_SERVER/$PRODUCT_SERVICE_IMAGE" -u $ACR_USERNAME -p $ACR_PASSWORD

printf "\n\n*** Retrieving Cosmos DB connection string ***\n"
COSMOSDB_CONNECTION_STRING=$(az cosmosdb list-connection-strings -n $COSMOSDB_NAME -g $RESOURCE_GROUP_NAME --query connectionStrings[0].connectionString -o tsv)
# append name of database to connection string
COSMOSDB_CONNECTION_STRING=`echo $COSMOSDB_CONNECTION_STRING | sed -e "s/\?/tailwind\?/"`

MONGODB_CONNECTION_STRING="mongodb://${USERNAME}:${PASSWORD}@${MONGO_IP_ADDRESS}:27017/tailwind"

printf "\n\n*** Configuring Product Service app settings ***\n"
az webapp config appsettings set -n $PRODUCT_SERVICE_NAME -g $RESOURCE_GROUP_NAME --settings "DB_CONNECTION_STRING=$MONGODB_CONNECTION_STRING" COLLECTION_NAME=inventory SEED_DATA=true

printf "\n\n*** Configuring Frontend to use ACR image ***\n"
az webapp config container set -n $FRONTEND_NAME -g $RESOURCE_GROUP_NAME -i "$ACR_SERVER/$FRONTEND_IMAGE" -u $ACR_USERNAME -p $ACR_PASSWORD

printf "\n\n*** Retrieving backend URLs ***\n"
#INVENTORY_SERVICE_BASE_URL="http://$(az webapp show -n $INVENTORY_SERVICE_NAME -g $RESOURCE_GROUP_NAME --query defaultHostName -o tsv)/"
PRODUCT_SERVICE_BASE_URL="http://$(az webapp show -n $PRODUCT_SERVICE_NAME -g $RESOURCE_GROUP_NAME --query defaultHostName -o tsv)/"
printf "\n$INVENTORY_SERVICE_BASE_URL\n$PRODUCT_SERVICE_BASE_URL\n"

printf "\n\n*** Configuring Frontend app settings ***\n"
az webapp config appsettings set -n $FRONTEND_NAME -g $RESOURCE_GROUP_NAME --settings "PRODUCT_SERVICE_BASE_URL=$PRODUCT_SERVICE_BASE_URL"

FRONTEND_BASE_URL="http://$(az webapp show -n $FRONTEND_NAME -g $RESOURCE_GROUP_NAME --query defaultHostName -o tsv)/"

# Finished with app service, go back to top level directory
cd ..\..\..\..

pwd

rm -rf IgniteTheTour

printf "\n\n*** Creating the SQL Manage Instance virtual network***\n\n"
az network vnet create -g $RESOURCE_GROUP_NAME -n $SQL_MI_VNET_NAME \
    --address-prefix 10.0.0.0/16 \
    --subnet-name $SQL_MI_SUBNET_NAME \
    --subnet-prefix 10.0.0.0/24

SQL_DMS_SUBNET_NAME=dms

printf "\n\n*** Creating the DMS subnet ***\n\n"
az network vnet subnet create -g $RESOURCE_GROUP_NAME --vnet-name $SQL_MI_VNET_NAME \
    --address-prefixes 10.0.1.0/24 \
    --name $SQL_DMS_SUBNET_NAME

DMS_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP_NAME -n $SQL_DMS_SUBNET_NAME --vnet-name $SQL_MI_VNET_NAME | jq -r .id)

#printf "\n\n*** Creating the SQL Managed Instance *** \n\n"
#az sql mi create -g $RESOURCE_GROUP_NAME -l $MAIN_REGION -n $SQL_MI_NAME \
#    -u $USERNAME -p $PASSWORD --subnet $SUBNET_ID \
#    --family Gen5 --edition GeneralPurpose --capacity 8 --storage 32GB --no-wait

printf "\n\n*** Creaeting the SQL Data Migration Service ***\n\n"
az dms create -g $RESOURCE_GROUP_NAME -l $MAIN_REGION -n $SQL_DMS_NAME \
    --sku-name Premium_4vCores --subnet $DMS_SUBNET_ID

printf "\n\n*** Creating VM for Inventory Service ***\n\n"
az vm create --resource-group $RESOURCE_GROUP_NAME --name $INVENTORY_SERVICE_VM_NAME --size Standard_D2s_v3 \
    --image UbuntuLTS --admin-username azureuser --generate-ssh-keys --subnet $DMS_SUBNET_ID --custom-data cloudinitdocker.sh

az vm user update -u azureuser --ssh-key-value "$(< ~/.ssh/id_rsa.pub)" -g $RESOURCE_GROUP_NAME -n $INVENTORY_SERVICE_VM_NAME

INVENTORY_VM_IP_ADDRESS=$(az vm list-ip-addresses -g $RESOURCE_GROUP_NAME -n $INVENTORY_SERVICE_VM_NAME | jq -r '.[0].virtualMachine.network.publicIpAddresses[0].ipAddress')

sed -i -e "s/INVENTORY_VM_IP_ADDRESS/${INVENTORY_VM_IP_ADDRESS}/g" postprocess.sh

INVENTORY_VM_IP_NAME=$(az vm list-ip-addresses -g $RESOURCE_GROUP_NAME -n $INVENTORY_SERVICE_VM_NAME | jq -r '.[0].virtualMachine.network.publicIpAddresses[0].name')
INVENTORY_VM_IP_FQDN=$(az network public-ip update -g $RESOURCE_GROUP_NAME -n $INVENTORY_VM_IP_NAME --dns-name $INVENTORY_SERVICE_VM_NAME | jq -r .dnsSettings.fqdn)

printf "\n\n*** Opening port 8080 on the Inventory Service VM ***\n\n"
az vm open-port --resource-group $RESOURCE_GROUP_NAME --name $INVENTORY_SERVICE_VM_NAME --port 8080

printf "\n\n*** Configuring the Frontend to point at the Inventory Service VM***\n\n"
az webapp config appsettings set -n $FRONTEND_NAME -g $RESOURCE_GROUP_NAME --settings "INVENTORY_SERVICE_BASE_URL=http://$INVENTORY_VM_IP_ADDRESS:8080"

printf "\n\n *** Configuring the post-processing Inventory VM script ***\n\n"
sed -i -e "s/REPLACE_CONTAINER_REGISTRY_USERNAME/${ACR_USERNAME}/g" inventoryvmconfigure.sh 
sed -i -e "s/REPLACE_CONTAINER_REGISTRY_PASSWORD/${ACR_PASSWORD}/g" inventoryvmconfigure.sh
sed -i -e "s/REPLACE_CONTAINER_REGISTRY_SERVER/${ACR_SERVER}/g" inventoryvmconfigure.sh
sed -i -e "s/REPLACE_INVENTORY_IMAGE_NAME/${INVENTORY_SERVICE_IMAGE}/g" inventoryvmconfigure.sh
sed -i -e "s/REPLACE_SQL_IP/${SQL2012_VM_IP_ADDRESS}/g" inventoryvmconfigure.sh
sed -i -e "s/REPLACE_SQL_USERNAME/${USERNAME}/g" inventoryvmconfigure.sh
sed -i -e "s/REPLACE_SQL_PASSWORD/${PASSWORD}/g" inventoryvmconfigure.sh

chmod +x postprocess.sh

printf "\n\n *** Creating the SQL Managed Instance *** \n"
az group deployment create -g $RESOURCE_GROUP_NAME --template-file managedinstancedeploy.json \
    --parameters managedInstanceName=$SQL_MI_NAME location=$MAIN_REGION administratorLogin=$USERNAME administratorLoginPassword=$PASSWORD virtualNetworkResourceGroupName=$RESOURCE_GROUP_NAME virtualNetworkName=$SQL_MI_VNET_NAME subnetName=$SQL_MI_SUBNET_NAME \
    --no-wait


printf "\n******************************************************\n"
printf "\n\n*** Deployment to $RESOURCE_GROUP_NAME completed ***\n"
printf "\n******************************************************\n"

printf "\n\n*** You're going to want to write all of the following down:*** \n\n"
printf "Front end url: $FRONTEND_BASE_URL\n"
printf "Product service url: $PRODUCT_SERVICE_BASE_URL\n"
# printf "Inventory service url: $INVENTORY_SERVICE_BASE_URL\n"
printf "Cosmos connection string: $COSMOSDB_CONNECTION_STRING\n"
printf "MongoDB VM connection string: $MONGODB_CONNECTION_STRING\n"
printf "SQL VM IP address: $SQL2012_VM_IP_ADDRESS\n"
printf "Inventory service VM url: http://${INVENTORY_VM_IP_FQDN}:8080\n"
printf "MongoDB VM IP address: $MONGO_IP_ADDRESS\n"
printf "\n\n *** All the other info will be found in the portal under the resource group ***\n\n"

printf "\n******************************************************\n"
printf "\n*** The SQL Managed Instance is still deploying. It will take up to 6 hours to finish. ***\n"
printf "\n*** Please run the postprocess.sh script right now. ***"
#printf "\n*** DON'T FORGET TO RUN THE DATAMIGRATIONSERVICE-DEPLOY.SH AFTER SQL MI DEPLOY FINISHES!!! ***\n"
printf "\n******************************************************\n"
