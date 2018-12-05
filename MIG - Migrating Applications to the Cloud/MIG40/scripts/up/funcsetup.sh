#!/usr/bin/env bash
set -eou pipefail
source ./scripts/variables.sh

cd ./src/reports
npm install
func extensions install
cd ../../

az group create --resource-group $(rgfunc) --location $(location)


# create storage account

az storage account create -g $(rgfunc) -n $(storageaccount) -l $(location) --sku Standard_LRS

#CONNECTION_STRING=$(az storage account show-connection-string --name $STORAGE_ACCOUNT_NAME | jq -r .connectionString)
#echo $CONNECTION_STRING

# create functionapp
az functionapp create -g $(rgfunc) -n $(funcname) \
    --storage-account $(storageaccount) \
    --consumption-plan-location $(location) 

FUNC_SQL_USERNAME=`cat ./src/reports/local.settings.json | jq .Values.SQL_USERNAME | sed 's/"//g'`
FUNC_SQL_PASSWORD=`cat ./src/reports/local.settings.json | jq .Values.SQL_PASSWORD | sed 's/"//g'`
FUNC_SQL_DATABASE=`cat ./src/reports/local.settings.json | jq .Values.SQL_DATABASE | sed 's/"//g'`
FUNC_SQL_SERVER=`cat ./src/reports/local.settings.json | jq .Values.SQL_SERVER | sed 's/"//g'`
FUNC_SENDGRID_API_KEY=`cat ./src/reports/local.settings.json | jq .Values.SENDGRID_API_KEY | sed 's/"//g'`
FUNC_SENDGRID_TEMPLATE_ID=`cat ./src/reports/local.settings.json | jq .Values.SENDGRID_TEMPLATE_ID | sed 's/"//g'`

az functionapp config appsettings set -g $(rgfunc) -n $(funcname) \
    --settings WEBSITE_NODE_DEFAULT_VERSION='8.11.1' \
        FUNCTIONS_WORKER_RUNTIME="node" \
        SQL_USERNAME="$FUNC_SQL_USERNAME" \
        SQL_PASSWORD="$FUNC_SQL_PASSWORD" \
        SQL_SERVER="$FUNC_SQL_SERVER" \
        SQL_DATABASE="$FUNC_SQL_DATABASE" \
        SENDGRID_API_KEY="$FUNC_SENDGRID_API_KEY" \
SENDGRID_TEMPLATE_ID="$FUNC_SENDGRID_TEMPLATE_ID"
