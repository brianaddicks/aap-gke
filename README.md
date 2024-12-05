# AAP on GKE

This repo contains the resources for installing Red Hat Ansible Automation Platform on GKE.
Please note that this is not officially supported by Red Hat.
While the focus of this document is on 2.5, a process for 2.4 was also tested and can be found
[here](https://github.com/brianaddicks/aap-gke/blob/main/README-2.4.md).
All of the steps below were performed from a RHEL 9 machine.

## Overview

Here's an overview of the process.

1. [Create a VPC and GKE Cluster](#create-a-vpc-and-gke-cluster)
1. [Create a Cloud SQL Postgres instance (Optional)](#enable-sql-auth-proxy-for-cloud-sql-optional)
1. [Install OLM](#install-olm)
1. [Expose AAP operator to GKE Cluster](#expose-aap-operator-to-gke-cluster)
1. [Enable Sql Auth Proxy for Cloud SQL (Optional)](#enable-sql-auth-proxy-for-cloud-sql-optional)
1. [Install AAP from operator](#install-aap-from-operator)
1. [Access AAP](#access-aap)

Also included in this document:

* [Redeploying with Existing Database](#redeploying-with-existing-database)
* [Upgrading AAP Operator](#upgrading-aap-operator)

## Create a VPC and GKE Cluster

### Install/Configure gcloud CLI

```
# add repo for gcloud binaries
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

### Create VPC/GKE

```
export GKE_PROJECT=YOUR_PROJECT_NAME
export GKE_CLUSTER_NAME=YOUR_CLUSTER_ANME
export GKE_REGION=YOUR_REGION
export GKE_AAP_NAMESPACE=aap-op

# switch context to your project
gcloud config set project $GKE_PROJECT

# create a basic vpc
gcloud compute networks create default --project=${GKE_PROJECT} --subnet-mode=auto --mtu=1460 --bgp-routing-mode=regional

# enable for filestore storage class
gcloud services enable file.googleapis.com

# enable kubernetes api
gcloud services enable container.googleapis.com

# create GKE cluster
gcloud beta container \
    --project "${GKE_PROJECT}" clusters create "${GKE_CLUSTER_NAME}" \
    --region "${GKE_REGION}" \
    --tier "standard" \
    --no-enable-basic-auth \
    --release-channel "regular" \
    --machine-type "e2-medium" \
    --image-type "COS_CONTAINERD" \
    --disk-type "pd-balanced" \
    --disk-size "100" \
    --metadata disable-legacy-endpoints=true \
    --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" \
    --num-nodes "3" \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET \
    --enable-ip-alias \
    --network "projects/${GKE_PROJECT}/global/networks/default" \
    --subnetwork "projects/${GKE_PROJECT}/regions/${GKE_REGION}/subnetworks/default" \
    --no-enable-intra-node-visibility \
    --default-max-pods-per-node "110" \
    --enable-ip-access \
    --security-posture=standard \
    --workload-vulnerability-scanning=disabled \
    --no-enable-master-authorized-networks \
    --no-enable-google-cloud-access \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver,GcpFilestoreCsiDriver \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade 1 \
    --max-unavailable-upgrade 0 \
    --binauthz-evaluation-mode=DISABLED \
    --enable-managed-prometheus \
    --enable-shielded-nodes \
    --workload-pool="${GKE_PROJECT}.svc.id.goog"

# connect to cluster
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${GKE_REGION} --project ${GKE_PROJECT}
```

## Create a Cloud SQL Postgres instance (Optional)

### Create CloudSQL Instance

```
# AAP 2.4
export GKE_DB_VERSION=POSTGRES_13

# AAP 2.5
export GKE_DB_VERSION=POSTGRES_15
export GKE_DB_INSTANCE=ansible
export GKE_DB_ROOT_PASSWORD=YOUR_DATABASE_ROOT_PASSWORD

# enable required apis
gcloud services enable sqladmin.googleapis.com
gcloud services enable servicenetworking.googleapis.com

# create private peering for communication between GKE and Cloud SQL
gcloud compute addresses create services-private-range \
    --global \
    --purpose=VPC_PEERING \
    --addresses=192.168.0.0 \
    --prefix-length=16 \
    --network=default

gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=services-private-range \
  --network=default

# deploy Cloud Sql instance
gcloud sql instances create ${GKE_DB_INSTANCE} \
    --database-version=${GKE_DB_VERSION} \
    --cpu=2 \
    --memory=8GiB \
    --region=${GKE_REGION} \
    --root-password=${GKE_DB_ROOT_PASSWORD} \
    --project=${GKE_PROJECT} \
    --no-assign-ip \
    --network=default
#    --enable-google-private-path \
#    --network=projects/${GKE_PROJECT}/global/networks/default \
#    --enable-private-service-connect \
#    --psc-auto-connections=project=${GKE_PROJECT},network=projects/${GKE_PROJECT}/global/networks/default
#    --authorized-networks=${GKE_SERVICE_NETWORK}
```

Enable Private IP/Path in console

### Create Databases and Users

```
gcloud sql databases create controller --instance=${GKE_DB_INSTANCE}
gcloud sql databases create hub --instance=${GKE_DB_INSTANCE}
gcloud sql databases create eda --instance=${GKE_DB_INSTANCE}
gcloud sql databases create platform --instance=${GKE_DB_INSTANCE}
gcloud sql users create ansible -i $GKE_DB_INSTANCE --password=${GKE_DB_AAP_PASSWORD}
```

### Connect and Enable hstore for Automation Hub database

```
# you'll be prompted for this password
echo $GKE_DB_ROOT_PASSWORD

# install postgresql client if needed
sudo dnf install -y postgresql

# connect to sql instance
gcloud sql connect ${GKE_DB_INSTANCE} -d hub --user=postgres

# Enable hstore extension
CREATE EXTENSION IF NOT EXISTS hstore;​
\q
```

### Prepare for SQL Auth Proxy (Optional)

If Client TLS auth is required, using Google's Sql Auth Proxy is the easiest path.
This combined with workload identity allows you to map k8s service accounts to Google services accounts for
authentication.

```
export GKE_SERVICE_ACCOUNT=ansible-cloudsql

# Create service account in GCP with cloudsql.client role
gcloud iam service-accounts create $GKE_SERVICE_ACCOUNT \
    --description="Ansible SA for SQL connection" \
    --display-name="${GKE_SERVICE_ACCOUNT}"
gcloud projects add-iam-policy-binding $GKE_PROJECT \
    --member="serviceAccount:${GKE_SERVICE_ACCOUNT}@${GKE_PROJECT}.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"

# Enable workload identity in GKE
# Only run if you didn't use the workload-pool flag when creating your cluster
# This could take up to 30 minutes to run
gcloud container clusters update ${GKE_CLUSTER_NAME} \
    --region "${GKE_REGION}" \
    --workload-pool="${GKE_PROJECT}.svc.id.goog"
```


## Install OLM

[Operator Lifecycle Manager](https://olm.operatorframework.io/) is used to maintain operators.

### Install Operator SDK CLI

You'll need to install the [Operator SDK CLI](https://sdk.operatorframework.io/docs/installation/).

```
# get platform information
export ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n $(uname -m) ;; esac)
export OS=$(uname | awk '{print tolower($0)}')

# download binary
export OPERATOR_SDK_DL_URL=https://github.com/operator-framework/operator-sdk/releases/download/v1.38.0
curl -LO ${OPERATOR_SDK_DL_URL}/operator-sdk_${OS}_${ARCH}

# install binary to your PATH
chmod +x operator-sdk_${OS}_${ARCH}
sudo mv operator-sdk_${OS}_${ARCH} /usr/local/bin/operator-sdk
```

### Install OLM on cluster

Install OLM using the [QuickStart](https://olm.operatorframework.io/docs/getting-started/) method

```
operator-sdk olm install --timeout=30m0s
```

## Expose AAP operator to GKE Cluster

These steps are detail [here](https://olm.operatorframework.io/docs/tasks/) on the OLM site.
You'll need to download/install the [opm client](https://github.com/operator-framework/operator-registry/releases).

### Create a Catalog

The catalog directory already has a working definiton for the AAP operator.
It currently includes the following bundle versions.

* 2.5-883
* 2.5-973
* 2.4-2119

The following steps detail how to create this from scratch.
Procedures for updating the available version of the AAP operator are [here](#upgrading-aap-operator).

```
# generate skeleton for operator
opm generate dockerfile catalog/aap-catalog
opm init ansible-automation-platform-operator \
    --default-channel=stable-2.5 \
    --description=./README.md \
    --icon=./aap-operator.svg \
    --output yaml > catalog/aap-catalog/ansible-automation-platform-operator.yaml

# render operator bundles into catalog file
opm render registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.5-883 \
    --output=yaml >> catalog/aap-catalog/ansible-automation-platform-operator.yaml

opm render registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.5-973 \
    --output=yaml >> catalog/aap-catalog/ansible-automation-platform-operator.yaml

opm render registry.redhat.io/ansible-automation-platform/platform-operator-bundle:2.4-2119 \
    --output=yaml >> catalog/aap-catalog/ansible-automation-platform-operator.yaml

# define update graph
cat << EOF >> catalog/aap-catalog/ansible-automation-platform-operator.yaml
---
schema: olm.channel
package: ansible-automation-platform-operator
name: stable-2.5
entries:
  - name: aap-operator.v2.5.0-0.1729742145
    replaces: aap-operator.v2.4.0-0.1730153340
  - name: aap-operator.v2.5.0-0.1733193761
    replaces: aap-operator.v2.5.0-0.1729742145
---
schema: olm.channel
package: ansible-automation-platform-operator
name: stable-2.4
entries:
  - name: aap-operator.v2.4.0-0.1730153340
EOF

# validate catalog file, this should return no output
opm validate catalog/aap-catalog

# build and push (use you're own container registry here)
export QUAY_USERNAME=YOUR_QUAY_USERNAME

podman build . \
    -f catalog/aap-catalog.Dockerfile \
    -t quay.io/${QUAY_USERNAME}/aap-catalog:latest
podman push quay.io/${QUAY_USERNAME}/aap-catalog:latest
```

### Create secrets for RH registry pulls

```
# make sure you're logged into the redhat registry
podman login registry.redhat.io

# create k8s namespace for deployment
kubectl create namespace ${AAP_NAMESPACE}
kubectl config set-context --current --namespace ${AAP_NAMESPACE}

# create pull secret for olm to pull the operator images
kubectl create secret generic rhregistry \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n olm

# create pull secret that will be used by the operator controllers
kubectl create secret generic redhat-operators-pull-secret \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n aap-op
```

### Make Catalog available on Cluster

Update the CatalogSource.yaml file to point to your container image made above.

```
# apply CatalogSource
kubectl apply -f CatalogSource.yaml -n olm

# check for pacakage availability, this will take a minute or two
kubectl get packagemanifest -n olm | grep AAP
```

### Install Operator

Update the `channel` and `InstallPlanApproval` in Subscription.yaml as desired.
The provided file uses `stable-2.5` and `Automatic`.

```
kubectl apply -f OperatorGroup.yaml -n aap-op
kubectl apply -f Subscription.yaml -n aap-op
```

## Enable Sql Auth Proxy for Cloud SQL (Optional)

If Client TLS authentication is desired for Cloud SQL, use this process

### Install SQL Auth Proxy Operator

The SQL Auth Proxy Operator is the easiest way to maintain the sidecar containers needed.
Helm is required to install the operator.

```
# Install Helm on RHEl
sudo curl -L https://mirror.openshift.com/pub/openshift-v4/clients/helm/latest/helm-linux-amd64 -o /usr/local/bin/helm
sudo chmod +x /usr/local/bin/helm

# Install Cloud SQL Proxy Operator
curl https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy-operator/v1.6.0/install.sh | bash
```

### Setup AuthProxy Operator Instances

```
# get your CloudSQL connectionName
export GKE_SQL_CONNECTIONNAME="$(gcloud sql instances describe $GKE_DB_INSTANCE \
    --format='value[](connectionName)')"

# create operator instances
for proxy_file in ./SqlAuthProxy/*.yaml
do
    export DEPLOYMENT_NAME=$(basename "$proxy_file" .yaml)
    cat $proxy_file | envsubst | kubectl apply -f -
done

# bind k8s service accounts to Google service accounts
declare -a ksas=(
    "ansible-controller"
    "ansible-eda"
    "ansible-gateway"
    "ansible-hub"
)

for ksa in "${ksas[@]}"
do
    gcloud iam service-accounts add-iam-policy-binding \
        --role="roles/iam.workloadIdentityUser" \
        --member="serviceAccount:${GKE_PROJECT}.svc.id.goog[${GKE_AAP_NAMESPACE}/${ksa}]" \
        ${GKE_SERVICE_ACCOUNT}@${GKE_PROJECT}.iam.gserviceaccount.com
done
```
## Install AAP from operator

This process is for AAP 2.5, for 2.4 go [here](README-2.4.md).

### External Database

If using an external database, create and apply secrets for the configuration.
You'll need one for each component: platform, controller, eda, automation hub.
The included definition file assumes the following secret names.

* automation-platform-postgres-configuration
* controller-postgres-configuration
* eda-postgres-configuration
* automationhub-postgres-configuration

Below is a sample secret.

```
---
apiVersion: v1
kind: Secret
metadata:
  name: automation-platform-postgres-configuration
  namespace: aap-op
stringData:
  host: '127.0.0.1'
  port: '5000'
  database: 'DBNAME'
  username: 'DBUSERNAME'
  password: 'DBPASSWORD'
  sslmode: 'prefer'
  type: 'unmanaged'
type: Opaque
```

### Set default ee pull creds (optional, only used for builtin EEs)

If the default Execution Environments that come with AAP are needed, valid Red Hat registry creds are required.
The process below assumes you are already logged into registry.redhat.io with podman.
Note that the AAP operator expects these in a specific format, the k8s pull secret created above cannot be used.

```
# grab creds from podman auth file
AUTH_KEY=$(jq -r '.auths["registry.redhat.io"].auth' "${XDG_RUNTIME_DIR}/containers/auth.json")
DECODED_AUTH=$(echo "$AUTH_KEY" | base64 -d)
AAP_EE_DEFAULT_PULL_USERNAME=$(echo "$DECODED_AUTH" | cut -d: -f1)
AAP_EE_DEFAULT_PULL_PASSWORD=$(echo "$DECODED_AUTH" | cut -d: -f2)

# create secret for AAP controller operator
kubectl create secret generic ansible-default-ee-pull \
    --from-literal=username="$AAP_EE_DEFAULT_PULL_USERNAME" \
    --from-literal=password="$AAP_EE_DEFAULT_PULL_PASSWORD" \
    --from-literal=url="registry.redhat.io"
```

### Install from operator

Some of the variable values below are set in a way specific to the lab environment used to develop this process.
Set them appropriately for the environment being used.
The definition files make a lot of assumptions.
Update them as needed.

```
# get DNS info
export GKE_PROJECT="YOURGCPPROJECT"

# get DNS zone info, set it appropriately for the environment
export GKE_DNS_ZONE=$(echo "$GKE_PROJECT" | sed 's/^openenv-\(.*\)$/\1.gcp.redhatworkshops.io/')

# operator-managed postgres
cat aap-definition.yaml | envsubst | kubectl apply -f -

# external postgres
cat aap-definition-external-db.yaml | envsubst | kubectl apply -f -
```

### Update DNS

The process below assumes Google Cloud DNS is being used.
Once the `ansible` service is available and has an external IP assigned, do the following to create an external DNS record for AAP.

```
export GKE_DNS_ZONE=$(echo "$GKE_PROJECT" | sed 's/^openenv-\(.*\)$/\1.gcp.redhatworkshops.io/')
export GKE_DNS_ZONE_NAME=$(echo "$GKE_PROJECT" | sed 's/^openenv-/dns-zone-/')
export GKE_AAP_INGRESS_IP=$(kubectl get service ansible -n aap-op -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# create
gcloud dns --project=${GKE_PROJECT} record-sets create "ansible.${GKE_DNS_ZONE}" --zone="${GKE_DNS_ZONE_NAME}" --type="A" --ttl="60" --rrdatas="${GKE_AAP_INGRESS_IP}"
```

### Postgres Changes

#### Operator-Managed Postgres

If using operator-managed Postgres, you need to patch the statefulset to apply the correct fsGroup.

```
kubectl patch statefulset.apps/ansible-postgres-15 -p '{"spec":{"template":{"spec":{"securityContext":{"fsGroup":26}}}}}' -n aap-op
```

#### Google Cloud Sql with Auth Proxy

If using Sql Auth Proxy, the Automation Hub service account needs to be updated.
Automation Hub doesn't support the service_account_annotations key.
Once the ansible-hub sa is created, annotate it and restart the automation-hub pods.

```
kubectl annotate serviceaccount ansible-hub \
        iam.gke.io/gcp-service-account=${GKE_SERVICE_ACCOUNT}@${GKE_PROJECT}.iam.gserviceaccount.com

kubectl delete pod -l=app.kubernetes.io/managed-by=automationhub-operator
```

### Access AAP

Once all pods are running, get the admin password from the k8s secret created by the AAP operator.
At this point the web interface should be accessible.

```
# get password
kubectl get secret ansible-admin-password -o jsonpath="{.data.password}" -n aap-op | base64 --decode ; echo

# get url
echo "http://ansible.${GKE_DNS_ZONE}"
```

## Redeploying with Existing Database

If the desire is to redeploy AAP with the existing database, the database encryption keys must be backed up and supplied to the operator during install.

### Backup Keys

```
# get existing db encryption keys
export CONTROLLER_SECRET_KEY=$(kubectl get secret ansible-controller-secret-key -o jsonpath="{.data.secret_key}" | base64 --decode; echo)
export EDA_DB_FIELDS_ENCRYPTION_KEY=$(kubectl get secret ansible-eda-db-fields-encryption-secret -o jsonpath="{.data.secret_key}" | base64 --decode; echo)
export HUB_DB_FIELDS_ENCRYPTION_KEY=$(kubectl get secret ansible-hub-db-fields-encryption -o jsonpath='{.data.database_fields\.symmetric\.key}' | base64 --decode; echo)
export PLATFORM_DB_FIELDS_ENCRYPTION_KEY=$(kubectl get secret ansible-db-fields-encryption-secret -o jsonpath='{.data.secret_key}' | base64 --decode; echo)

# create k8s secrets from those keys
kubectl create secret generic backup-ansible-controller-secret-key --from-literal secret_key=$CONTROLLER_SECRET_KEY
kubectl create secret generic backup-ansible-eda-db-fields-encryption-secret --from-literal secret_key=$EDA_DB_FIELDS_ENCRYPTION_KEY
kubectl create secret generic backup-ansible-hub-db-fields-encryption --from-literal "database_fields.symmetric.key"=$HUB_DB_FIELDS_ENCRYPTION_KEY
kubectl create secret generic backup-ansible-db-fields-encryption-secret --from-literal secret_key=$PLATFORM_DB_FIELDS_ENCRYPTION_KEY
```

### Delete AAP Instance

```
kubectl delete AnsibleAutomationPlatform ansible
```

### Redeploy

```
# external postgres
cat aap-definition-external-db-redeploy.yaml | envsubst | kubectl apply -f -
```

### Update DNS

The process below assumes Google Cloud DNS is being used.
Once the `ansible` service is available and has an external IP assigned, do the following to create an external DNS record for AAP.

```
export GKE_DNS_ZONE=$(echo "$GKE_PROJECT" | sed 's/^openenv-\(.*\)$/\1.gcp.redhatworkshops.io/')
export GKE_DNS_ZONE_NAME=$(echo "$GKE_PROJECT" | sed 's/^openenv-/dns-zone-/')
export GKE_AAP_INGRESS_IP=$(kubectl get service ansible -n aap-op -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# create
gcloud dns --project=${GKE_PROJECT} record-sets update "ansible.${GKE_DNS_ZONE}" --zone="${GKE_DNS_ZONE_NAME}" --type="A" --ttl="60" --rrdatas="${GKE_AAP_INGRESS_IP}"
```

### Access AAP

The admin password will be stored in the database and will be the same as before.

```
# get url
echo "http://ansible.${GKE_DNS_ZONE}"
```

## Upgrading AAP Operator

To upgrade the AAP operator, the OLM Catalog needs to be updated.

### Add New Bundle to OLM Catalog

```
# set new bundle version
export NEW_AAP_BUNDLE_VERSION=2.5-999

# render operator bundles into catalog file
opm render registry.redhat.io/ansible-automation-platform/platform-operator-bundle:${NEW_AAP_BUNDLE_VERSION} \
    --output=yaml >> aap-catalog/catalog/ansible-automation-platform-operator.yaml
```

Update the olm channel in `ansible-automation-platform-operator.yaml` as per [this documentation](https://olm.operatorframework.io/docs/concepts/olm-architecture/operator-catalog/creating-an-update-graph/).

### Validate and Push New Catalog

```
# validate catalog file, this should return no output
opm validate aap-catalog

# build and push (use you're own container registry here)
export QUAY_USERNAME=YOUR_QUAY_USERNAME

podman build . \
    -f aap-catalog.Dockerfile \
    -t quay.io/${QUAY_USERNAME}/aap-catalog:latest
podman push quay.io/${QUAY_USERNAME}/aap-catalog:latest
```

### Upgrade Operator

If the Subscription `installPlanApproval` is set to `Automatic`, the operator will automatically update all pods.
Timing will depend on the `updateStrategy` defined in the CatalogSource.
If `installPlanApproval` is set to `Manual`, use the following process to approve the update.

```
# get install plan name
kubectl get ip

# approve install plan
kubectl edit ip install-nlwcw -n foo
```