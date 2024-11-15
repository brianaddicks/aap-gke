# AAP on GKE

## Get Started

Created VPC, and subnet
Created GKE

# Install prereqs
```
# google cloud repo
sudo tee -a /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM

# install google-cloud-cli kubectl, gke auth plugin
sudo dnf -y install google-cloud-cli kubectl google-cloud-sdk-gke-gcloud-auth-plugin
```

## Install OPM

https://docs.openshift.com/container-platform/4.17/cli_reference/opm/cli-opm-install.html

```
operator-sdk olm install --timeout=30m0s
```

## Connect to cluster
```
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${GKE_REGION} --project ${GKE_PROJECT}
```

## Install OLM

https://olm.operatorframework.io/docs/getting-started/

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

## Create secret for RH registry pulls

```
kubectl create secret generic rhregistry \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n olm
```

## Make Catalog available on Cluster

```
kubectl apply -f CatalogSource.yaml -n olm

# List available packages
kubectl get packagemanifest -n olm
```
## Install Operator

```
kubectl apply -f OperatorGroup.yaml -n olm
kubectl apply -f Subscription.yaml -n olm
```

Should be able to approve an Install Plan at this point, but it's not showing up.