#!/usr/bin/env bash

if [ ! -f $HOME/.nephio-gcp ]; then
    echo "Environment variable file (\$HOME/.nephio-gcp) for gcp not found."
    exit 1
fi

. $HOME/.nephio-gcp

if [ $1 ]; then
    REGION=$1
    LOCATION=$REGION
fi

function checkStatus {
    if [ $? -ne 0 ]; then
        echo "Something went wrong"
        exit 1
    fi
}

######################################################### CONFIG CONTROLLER ###########################################################
printf "Provisioning Config Controller\n"

gcloud anthos config controller create nephio-cc \
    --location=$REGION \
    --full-management
checkStatus

export SA_EMAIL="$(kubectl get ConfigConnectorContext -n config-control \
    -o jsonpath='{.items[0].spec.googleServiceAccount}' 2> /dev/null)"
checkStatus

gcloud projects add-iam-policy-binding $PROJECT \
    --member "serviceAccount:${SA_EMAIL}" \
    --role roles/editor \
    --project $PROJECT
checkStatus

gcloud projects add-iam-policy-binding $PROJECT \
    --member "serviceAccount:${SA_EMAIL}" \
    --role roles/source.admin \
    --project $PROJECT
checkStatus

# ########################################################### GITOPS FOR CONFIG CONTROLLER ###########################################################
printf "\nSetting Up GitOps for Config Controller\n"

gcloud source repos create config-control
checkStatus

gcloud source repos clone config-control
checkStatus

kpt pkg get --for-deployment https://github.com/nephio-project/catalog.git/distros/gcp/cc-rootsync@main
checkStatus

kpt fn eval cc-rootsync --image gcr.io/kpt-fn/search-replace:v0.2.0 --match-name gcp-context -- 'by-path=data.project-id' "put-value=${PROJECT}"
checkStatus

kpt fn render cc-rootsync/
checkStatus

kubectl apply -f cc-rootsync/rootsync.yaml
checkStatus

# ########################################################### NEPHIO MGMT CLUSTER ###########################################################
printf "\nProvisioning Nephio Management Cluster\n"

cd config-control
kpt pkg get --for-deployment https://github.com/nephio-project/catalog.git/infra/gcp/cc-cluster-gke-std-csr-cs@main nephio
checkStatus

git add nephio
git commit -m "Initial clone of GKE package"

yq -i '.spec.nodeConfig.diskType = "pd-standard"' nephio/nodepool.yaml
git add nephio
git commit -m "Add disktype in nodepool"

kpt fn eval nephio --image gcr.io/kpt-fn/search-replace:v0.2.0 --match-name gcp-context -- 'by-path=data.project-id' "put-value=${PROJECT}"
kpt fn eval nephio --image gcr.io/kpt-fn/search-replace:v0.2.0 --match-name gcp-context -- 'by-path=data.location' "put-value=${LOCATION}"
checkStatus

kpt fn render nephio
checkStatus

git add .
git commit -m "Fully configured Nephio management cluster package"
git push
checkStatus

printf "\nwait for cluster to be provisioned and reconciled\n"
sleep 720

while true; do
    echo "wait for credentials..."
    gcloud container clusters get-credentials --location $LOCATION nephio 2> /dev/null
    [[ $? -eq 0 ]] && break
    sleep 5
done

cd ..

########################################################### NEPHIO COMPONENTS ###########################################################
printf "\nInstalling the Nephio Components\n"

gcloud source repos clone nephio
checkStatus

cd nephio
kpt pkg get --for-deployment https://github.com/nephio-project/catalog.git/distros/gcp/nephio-mgmt@main
checkStatus

git add nephio-mgmt/
git commit -m "Initial checking of nephio-mgmt"

rm -rf nephio-mgmt/nephio-webui
kpt pkg get --for-deployment https://github.com/nephio-project/nephio-packages/nephio-webui@main nephio-mgmt
checkStatus

git restore nephio-mgmt/nephio-webui/service.yaml
kpt fn eval nephio-mgmt --image gcr.io/kpt-fn/search-replace:v0.2.0 --match-name gcp-context -- 'by-path=data.project-id' "put-value=${PROJECT}"
kpt fn eval nephio-mgmt --image gcr.io/kpt-fn/search-replace:v0.2.0 --match-name gcp-context -- 'by-path=data.location' "put-value=${LOCATION}"
checkStatus

kpt fn render nephio-mgmt/
checkStatus

git add .
git commit -m "Fully configured Nephio component package"
git push
checkStatus

git tag nephio-mgmt/v1
git push --tags
checkStatus

printf "\nInstallation completed\n"
