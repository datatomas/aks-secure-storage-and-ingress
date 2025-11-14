
#0. Create certificate in Azure Key Vault
az keyvault certificate create \
  --vault-name kv-front-app-prb-01 \
  --name front-app-prb-com-co \
  --policy "$(az keyvault certificate get-default-policy \
    | jq '.subject="CN=yourportal.com"' )"

#1. Download the PFX/RAW certificate
az keyvault secret download \
  --vault-name kv-front-app-prb-01 \
  --name front-app-prb-com-co \
  --file front-app-prb.pfx

#2. Extract private key (with passphrase)
openssl pkcs12 -in front-app-prb.pfx -nocerts -nodes -out tls_with_pass.key -legacy

#3. Remove passphrase from key
openssl rsa -in tls_with_pass.key -out tls.key

#4. Extract certificate
openssl pkcs12 -in front-app-prb.pfx -clcerts -nokeys -out tls.crt -legacy

#5. Create Kubernetes TLS secret
kubectl create secret tls front-app-prb-tls \
  --cert=tls.crt \
  --key=tls.key \
  -n <namespace>
