# AAP on GKE

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

gcloud init
```

## Create VPC/GKE

```
gcloud compute networks create aap-gke --project=${GKE_PROJECT} --subnet-mode=auto --mtu=1460 --bgp-routing-mode=regional

gcloud beta container --project "${GKE_PROJECT}" clusters create "${GKE_CLUSTER_NAME}" --region "${GKE_REGION}" --tier "standard" --no-enable-basic-auth --cluster-version "1.30.5-gke.1443001" --release-channel "regular" --machine-type "e2-medium" --image-type "COS_CONTAINERD" --disk-type "pd-balanced" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "3" --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET --enable-ip-alias --network "projects/${GKE_PROJECT}/global/networks/aap-gke" --subnetwork "projects/${GKE_PROJECT}/regions/${GKE_REGION}/subnetworks/aap-gke" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --enable-ip-access --security-posture=standard --workload-vulnerability-scanning=disabled --no-enable-master-authorized-networks --no-enable-google-cloud-access --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --binauthz-evaluation-mode=DISABLED --enable-managed-prometheus --enable-shielded-nodes
```

## Connect to cluster
```
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${GKE_REGION} --project ${GKE_PROJECT}
```

## Install OPM

https://docs.openshift.com/container-platform/4.17/cli_reference/opm/cli-opm-install.html

```
operator-sdk olm install --timeout=30m0s
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

opm render registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.4-2119 \
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
kubectl create namespace aap-op

kubectl create secret generic rhregistry \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n olm

kubectl create secret generic redhat-operators-pull-secret \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n aap-op

kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}' -n aap-op
kubectl patch serviceaccount ansible-gateway -p '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}' -n aap-op
```

## Make Catalog available on Cluster

```
kubectl apply -f CatalogSource.yaml -n olm

# List available packages
kubectl get packagemanifest -n olm | grep AAP
```
## Install Operator

```
kubectl apply -f OperatorGroup.yaml -n aap-op
kubectl apply -f Subscription.yaml -n aap-op
```

## Create AAP Instance

```
kubectl apply -f aap-definition.yaml
```

## Patch postgres

```
kubectl patch statefulset.apps/ansible-postgres-15 -p '{"spec":{"template":{"spec":{"containers":[{"name":"postgres","securityContext":{"fsGroup":26}}]}}}}' -n aap-op
```

Should be able to approve an Install Plan at this point, but it's not showing up.