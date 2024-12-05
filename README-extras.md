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
