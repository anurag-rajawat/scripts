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

printf "Uninstallation has started\n"

repos=$(gcloud source repos list | cut -d ' ' -f 1 | sed -E '1d')
checkStatus
for repo in $repos; do
    printf 'Y' | gcloud source repos delete $repo
    checkStatus
done

printf 'Y' | gcloud anthos config controller delete nephio-cc --location=$REGION
checkStatus

clusters=$(gcloud container clusters list | cut -d ' ' -f 1 | sed -E '1d')

for cluster in $clusters; do
    printf 'Y' | gcloud container clusters delete $cluster --location=$REGION
    checkStatus
done

rm -rf cc-rootsync config-control nephio

printf "Uninstallation has completed\n"

