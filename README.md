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

gcloud beta container \
    --project "${GKE_PROJECT}" clusters create "${GKE_CLUSTER_NAME}" \
    --region "${GKE_REGION}" \
    --tier "standard" \
    --no-enable-basic-auth \
    --cluster-version "1.30.5-gke.1443001" \
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
export AAP_NAMESPACE=aap-op
kubectl create namespace ${AAP_NAMESPACE}
kubectl config set-context --current --namespace ${AAP_NAMESPACE}

kubectl create secret generic rhregistry \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n olm

kubectl create secret generic redhat-operators-pull-secret \
--from-file=.dockerconfigjson=${XDG_RUNTIME_DIR}/containers/auth.json \
--type=kubernetes.io/dockerconfigjson -n aap-op
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

# Setup External DB (Optional)

Assumes GCP CloudSQL

## Create CloudSQL Instance

```
# export GKE_DB_VERSION=POSTGRES_13 # AAP 2.4
export GKE_DB_VERSION=POSTGRES_15 # AAP 2.5
export GKE_DB_INSTANCE=ansible
# export GKE_SERVICE_NETWORK=<your_service_network>
export GKE_DB_ROOT_PASSWORD=<your_password>

# create instance
gcloud services enable sqladmin.googleapis.com
gcloud services enable servicenetworking.googleapis.com

gcloud compute addresses create services \
    --purpose=VPC_PEERING \
    --subnet=default

gcloud sql instances create ${GKE_DB_INSTANCE} \
    --database-version=${GKE_DB_VERSION} \
    --cpu=2 \
    --memory=8GiB \
    --region=${GKE_REGION} \
    --root-password=${GKE_DB_ROOT_PASSWORD} \
    --project=${GKE_PROJECT} \
    --no-assign-ip \
#    --enable-google-private-path \
#    --network=projects/${GKE_PROJECT}/global/networks/default \
#    --enable-private-service-connect \
#    --psc-auto-connections=project=${GKE_PROJECT},network=projects/${GKE_PROJECT}/global/networks/default
#    --authorized-networks=${GKE_SERVICE_NETWORK}
```

Enable Private IP/Path in console

## Create Databases and Users

```
gcloud sql databases create controller --instance=${GKE_DB_INSTANCE}
gcloud sql databases create hub --instance=${GKE_DB_INSTANCE}
gcloud sql databases create eda --instance=${GKE_DB_INSTANCE}
gcloud sql databases create platform --instance=${GKE_DB_INSTANCE}
gcloud sql users create ansible -i $GKE_DB_INSTANCE --password=${GKE_DB_AAP_PASSWORD}
```

## Get Certs for SQL Auth

```
rm ./*.pem
gcloud sql ssl client-certs create ansible client-key.pem \
    --instance=${GKE_DB_INSTANCE}
gcloud sql ssl client-certs describe ansible \
    --instance=${GKE_DB_INSTANCE} \
    --format="value(cert)" > client-cert.pem
gcloud sql instances describe ${GKE_DB_INSTANCE} \
    --format="value(serverCaCert.cert)" > server-ca.pem

kubectl create secret tls ansible-postgres-cert \
    --cert="$(realpath ./client-cert.pem)" \
    --key="$(realpath ./client-key.pem)"

kubectl create secret generic ansible-custom-certs \
    --from-file=bundle-ca.crt="$(realpath ./server-ca.pem)"
```


## Connect and Enable hstore

```
sudo dnf install -y postgresql
gcloud sql connect ${GKE_DB_INSTANCE} -d hub --user=postgres

CREATE EXTENSION IF NOT EXISTS hstore;​
\q
```


## Setup SQL Auth Proxy

```
export GKE_SERVICE_ACCOUNT=ansible-cloudsql
export GKE_AAP_NAMESPACE=aap-op

# Create service account in GCP
gcloud iam service-accounts create $GKE_SERVICE_ACCOUNT \
    --description="Ansible SA for SQL connection" \
    --display-name="${GKE_SERVICE_ACCOUNT}"
gcloud projects add-iam-policy-binding $GKE_PROJECT \
    --member="serviceAccount:${GKE_SERVICE_ACCOUNT}@${GKE_PROJECT}.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"

# Enable workload identity in GKE
# Only run if you didn't use the workload-pool flag when creating your cluster
gcloud container clusters update ${GKE_CLUSTER_NAME} \
    --region "${GKE_REGION}" \
    --workload-pool="${GKE_PROJECT}.svc.id.goog"
```

## SQL Auth Proxy Operator

```
# Install Helm on RHEl
sudo curl -L https://mirror.openshift.com/pub/openshift-v4/clients/helm/latest/helm-linux-amd64 -o /usr/local/bin/helm
sudo chmod +x /usr/local/bin/helm

# Install Cloud SQL Proxy Operator
curl https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy-operator/v1.6.0/install.sh | bash
```

## Setup AuthProxy Operator Instances

```
# Get your CloudSQL connectionName
export GKE_SQL_CONNECTIONNAME="$(gcloud sql instances describe $GKE_DB_INSTANCE \
    --format='value[](connectionName)')"

# Create operator instances
for proxy_file in ./SqlAuthProxy/*.yaml
do
    export DEPLOYMENT_NAME=$(basename "$proxy_file" .yaml)
    cat $proxy_file | envsubst | kubectl apply -f -
done

# Bind k8s service accounts to Google service accounts
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

Cloud Filestore API Enabled, Filestore CSI enabled for cluster, correct cacert playbook

## Fix cacert playbook

```
# Get gateway controller operator pod name
export AAP_GW_DEPLOYMENT_NAME=aap-gateway-operator-controller-manager
export AAP_GW_REPLICASET_NAME=`kubectl describe deployment $AAP_GW_DEPLOYMENT_NAME \
    | grep "^NewReplicaSet" \
    | awk '{print $2}'`
export AAP_GW_POD_HASH_LABEL=`kubectl get rs $AAP_GW_REPLICASET_NAME \
    -o jsonpath="{.metadata.labels.pod-template-hash}"`
export AAP_GW_POD_NAME=`kubectl get pods -l \
    pod-template-hash=$AAP_GW_POD_HASH_LABEL --show-labels \
    | tail -n +2 | awk '{print $1}'`

export AAP_GW_FIX_OLD_PATTERN='\s*bundle_cacert_secret'
export AAP_GW_FIX_NEW_PATTERN='\ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ bundle_cacert_secret'
export AAP_GW_FIX_PATH='/opt/ansible/roles/ansibleautomationplatform/tasks/inject_platform_custom_spec.yml'
export AAP_GW_FIX_CMD="sed -i -e 's/${AAP_GW_FIX_OLD_PATTERN}/${AAP_GW_FIX_NEW_PATTERN}/' ${AAP_GW_FIX_PATH}"

kubectl exec --stdin --tty pod/${AAP_GW_POD_NAME} -- /bin/bash -c "${AAP_GW_FIX_CMD}"

# check results
kubectl exec --stdin --tty pod/${AAP_GW_POD_NAME} -- /bin/bash -c "cat ${AAP_GW_FIX_PATH}"

```

## Create filestore with network if no default exists
```
kubectl apply -f filestore-example-class.yaml
```

## Deploy AAP 2.5

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
  password: 'DBOASSWIRD'
  sslmode: 'prefer'
  type: 'unmanaged'
type: Opaque
```

### Install from operator
```
# get DNS info
export GKE_PROJECT="YOURGCPPROJECT"
export GKE_DNS_ZONE=$(echo "$GKE_PROJECT" | sed 's/^openenv-\(.*\)$/\1.gcp.redhatworkshops.io/') # demo environment only, set as needed

# operator-managed postgres
cat aap-definition.yaml | envsubst | kubectl apply -f -

# external postgres
cat aap-definition-external-db.yaml | envsubst | kubectl apply -f -
```
# NOTE you will need to update public_base_url in the EDA section of aap-definition.yaml based on what the final URL you intend (load balancer Virtual Server, GCP DNS, etc) to use or Event Streams will not work

### Postgres

#### Operator-Managed Postgres

If using operator-managed Postgres, you need to patch the statefulset to apply the correct fsGroup.

```
kubectl patch statefulset.apps/ansible-postgres-15 -p '{"spec":{"template":{"spec":{"securityContext":{"fsGroup":26}}}}}' -n aap-op
```

#### Google Cloud Sql with Auth Proxy

Automation Hub doesn't support the service_account_annotations key.
Once the ansible-hub sa is created, annotate it and restart the automation-hub pods.

```
kubectl annotate serviceaccount ansible-hub \
        iam.gke.io/gcp-service-account=${GKE_SERVICE_ACCOUNT}@${GKE_PROJECT}.iam.gserviceaccount.com

kubectl delete pod -l=app.kubernetes.io/managed-by=automationhub-operator
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

gcloud dns --project=${GKE_PROJECT} record-sets create "ansible.${GKE_DNS_ZONE}" --zone="${GKE_DNS_ZONE_NAME}" --type="A" --ttl="60" --rrdatas="${GKE_AAP_INGRESS_IP}"
```

# Redeploying

If you need to redeploy AAP with the an existing database, you need to get the database encryption keys and supply them to the operator.

## Backup Keys

```
export CONTROLLER_SECRET_KEY=$(kubectl get secret ansible-controller-secret-key -o jsonpath="{.data.secret_key}" | base64 --decode; echo)
export EDA_DB_FIELDS_ENCRYPTION_KEY=$(kubectl get secret ansible-eda-db-fields-encryption-secret -o jsonpath="{.data.secret_key}" | base64 --decode; echo)
export HUB_DB_FIELDS_ENCRYPTION_KEY=$(kubectl get secret ansible-hub-db-fields-encryption -o jsonpath='{.data.database_fields\.symmetric\.key}' | base64 --decode; echo)
export PLATFORM_DB_FIELDS_ENCRYPTION_KEY=$(kubectl get secret ansible-db-fields-encryption-secret -o jsonpath='{.data.secret_key}' | base64 --decode; echo)

kubectl create secret generic backup-ansible-controller-secret-key --from-literal secret_key=$CONTROLLER_SECRET_KEY
kubectl create secret generic backup-ansible-eda-db-fields-encryption-secret --from-literal secret_key=$EDA_DB_FIELDS_ENCRYPTION_KEY
kubectl create secret generic backup-ansible-hub-db-fields-encryption --from-literal "database_fields.symmetric.key"=$HUB_DB_FIELDS_ENCRYPTION_KEY
kubectl create secret generic backup-ansible-db-fields-encryption-secret --from-literal secret_key=$PLATFORM_DB_FIELDS_ENCRYPTION_KEY
```

## Delete Instance

```
kubectl delete AnsibleAutomationPlatform ansible
```

## Redeploy

```
# external postgres
cat aap-definition-external-db-redeploy.yaml | envsubst | kubectl apply -f -
```