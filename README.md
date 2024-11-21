# AAP on GKE

## Install prereqs
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
gcloud config set project $GKE_PROJECT

gcloud compute networks create default --project=${GKE_PROJECT} --subnet-mode=auto --mtu=1460 --bgp-routing-mode=regional

gcloud services enable file.googleapis.com

gcloud beta container --project "${GKE_PROJECT}" clusters create "${GKE_CLUSTER_NAME}" --region "${GKE_REGION}" --tier "standard" --no-enable-basic-auth --cluster-version "1.30.5-gke.1443001" --release-channel "regular" --machine-type "e2-medium" --image-type "COS_CONTAINERD" --disk-type "pd-balanced" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --num-nodes "3" --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET --enable-ip-alias --network "projects/${GKE_PROJECT}/global/networks/default" --subnetwork "projects/${GKE_PROJECT}/regions/${GKE_REGION}/subnetworks/default" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --enable-ip-access --security-posture=standard --workload-vulnerability-scanning=disabled --no-enable-master-authorized-networks --no-enable-google-cloud-access --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver,GcpFilestoreCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --binauthz-evaluation-mode=DISABLED --enable-managed-prometheus --enable-shielded-nodes
```

## Connect to cluster
```
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${GKE_REGION} --project ${GKE_PROJECT}
```

## Install OPM

https://docs.openshift.com/container-platform/4.17/cli_reference/opm/cli-opm-install.html

## Install OLM

https://olm.operatorframework.io/docs/getting-started/

```
operator-sdk olm install --timeout=30m0s
```

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

## Optional (Create Cloud SQL Instance)

```
export GKE_DB_VERSION=POSTGRES_13

gcloud services enable sqladmin.googleapis.com

gcloud sql instances create ${GKE_DB_INSTANCE} \
    --database-version=${GKE_DB_VERSION} \
    --cpu=2 \
    --memory=8GiB \
    --region=${GKE_REGION} \
    --root-password=${GKE_DB_ROOT_PASSWORD} \
    --project=${GKE_PROJECT}
```

## Create AAP Instance

```
# 2.4
kubectl apply -f aap2.4-definition.yaml
```

## Patch postgres

```
# 2.4
kubectl patch statefulset.apps/ansible-controller-postgres-13 -p '{"spec":{"template":{"spec":{"securityContext":{"fsGroup":26}}}}}' -n aap-op
```

## Once all pods are running verify by using:

```
kubectl get pods -n aap-op
```

## Get URL address (this will take a minute as the ingress is created)
```
kubectl get ingress ansible-controller-ingress -n aap-op

# Create DNS record
export GKE_DNS_ZONE=$(echo "$GKE_PROJECT" | sed 's/^openenv-\(.*\)$/\1.gcp.redhatworkshops.io/')
export GKE_DNS_ZONE_NAME=$(echo "$GKE_PROJECT" | sed 's/^openenv-/dns-zone-/')
export GKE_AAP_INGRESS_IP=$(kubectl get ingress ansible-controller-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

gcloud dns --project=${GKE_PROJECT} record-sets create "ansible.${GKE_DNS_ZONE}" --zone="${GKE_DNS_ZONE_NAME}" --type="A" --ttl="60" --rrdatas="${GKE_AAP_INGRESS_IP}"
```

## Wait for Ingress to be available (this will take a few minutes). Then get the secret

```
kubectl get secret ansible-controller-admin-password -o jsonpath="{.data.password}" -n aap-op | base64 --decode ; echo
```

# Install Automation Hub

Cloud Filestore API Enabled, Filestore CSI enabled for cluster (done when creating cluster above)

Create filestore with network if no default exists
```
kubectl apply -f filestore-example-class.yaml
```

## Deploy Automation Hub
```
kubectl apply -f hub.yaml
```

## Patch postgres
```
kubectl patch statefulset.apps/automationhub-postgres-13 -p '{"spec":{"template":{"spec":{"securityContext":{"fsGroup":26}}}}}' -n aap-op
```

Allow Deployment to fully complete

## Expose web
```
kubectl expose deployment automationhub-web --name automation-hub-external-svc --type NodePort -n aap-op
```

## Add Ingress
```
kubectl apply -f ingress-hub.yaml
```
## Get URL address (this will take a minute as the ingress is created)
```
kubectl get ingress hub -n aap-op
```
## Get Automation Hub Secret
```
kubectl get secret automationhub-admin-password -o jsonpath="{.data.password}" -n aap-op | base64 --decode ; echo
```

## Deploy Automation EDA Controller
```
kubectl apply -f eda.yaml
```

## Patch postgres
```
kubectl patch statefulset.apps/eda-postgres-13 -p '{"spec":{"template":{"spec":{"securityContext":{"fsGroup":26}}}}}' -n aap-op
```

Allow Deployment to fully complete

## Get URL address (this will take a minute as the ingress is created)
```
kubectl get ingress eda-ingress -n aap-op
```
## Get Automation EDA Secret
```
kubectl get secret eda-admin-password -o jsonpath="{.data.password}" -n aap-op | base64 --decode ; echo
```

# AAP 2.5

Cloud Filestore API Enabled, Filestore CSI enabled for cluster

## Create filestore with network if no default exists
```
kubectl apply -f filestore-example-class.yaml
```

## Deploy AAP 2.5
```
kubectl apply -f aap.yaml
```
#NOTE you will need to update public_base_url in the EDA section based on what the final URL you intend to use or Event Streams will not work

## Patch Postgres Database

```
kubectl patch statefulset.apps/ansible-postgres-15 -p '{"spec":{"template":{"spec":{"securityContext":{"fsGroup":26}}}}}' -n aap-op
```

Once deployed

```
kubectl get secret ansible-admin-password -o jsonpath="{.data.password}" -n aap-op | base64 --decode ; echo
```

If setting up DNS in GCP
```
export GKE_PROJECT="YOURGCPPROJECT"
export GKE_DNS_ZONE=$(echo "$GKE_PROJECT" | sed 's/^openenv-\(.*\)$/\1.gcp.redhatworkshops.io/')
export GKE_DNS_ZONE_NAME=$(echo "$GKE_PROJECT" | sed 's/^openenv-/dns-zone-/')
export GKE_AAP_INGRESS_IP=$(kubectl get service ansible -n aap-op -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

gcloud dns --project=${GKE_PROJECT} record-sets update "ansible.${GKE_DNS_ZONE}" --zone="${GKE_DNS_ZONE_NAME}" --type="A" --ttl="60" --rrdatas="${GKE_AAP_INGRESS_IP}"
```

