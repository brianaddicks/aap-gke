# AAP on GKE

## Get Started

Created VPC, and subnet
Created GKE
Install Google Cloud CLI and kubectl and  gke-gcloud-auth-plugin and opm

## Connect to cluster
```
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${GKE_REGION} --project ${GKE_PROJECT}
```

## Install OLM

kubectl create -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.30.0/crds.yaml


kubectl apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.30.0/olm.yaml

## Create a Catalog

```
cd catalog
opm generate dockerfile aap-catalog
opm init ansible-automation-platform-operator \
    --default-channel=stable-2.5 \
    --description=./README.md \
    --icon=./aap-operator.svg \
    --output yaml > cool-catalog/operator.yaml

opm render registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.5-883 \
    --output=yaml >> aap-catalog/ansible-automation-platform-operator.yaml

cat << EOF >> cool-catalog/ansible-automation-platform-operator.yaml
---
schema: olm.channel
package: ansible-automation-platform-operator
name: stable-2.5
entries:
  - name: aap-operator.v2.5.0-0.1729742145
EOF

opm validate aap-catalog

podman build . \
    -f aap-catalog.Dockerfile \
    -t quay.io/rh_ee_baddicks/aap-catalog:latest
podman push quay.io/rh_ee_baddicks/aap-catalog:latest
```
## Make Catalog available on Cluster

```
kubectl apply -f CatalogSource.yaml -n operators

# List available packages
kubectl get packagemanifest -n operators
```
## Install Operator

```
kubectl apply -f OperatorGroup.yaml -n operators
kubectl apply -f Subscription.yaml -n operators
```

Should be able to approve an Install Plan at this point, but it's no showing up.

## Create secret for RH registry pulls

```
kubectl create secret generic rhregistry \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson
```