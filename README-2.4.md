
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

Create filestore with network if no default exists (you must update the network to match the cluster network name)
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

## Create filestore with network if no default exists (you must update the network to match the cluster network name)
```
kubectl apply -f filestore-example-class.yaml
```