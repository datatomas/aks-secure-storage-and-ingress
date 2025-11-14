#0 create the secret and download it from kv

az keyvault certificate create \
  --vault-name kv-portalxm-prb-01 \
  --name portalxm-prb-xm-com-co \
  --policy "$(az keyvault certificate get-default-policy \
    | jq '.subject="CN=yourportal.com"' )"
az keyvault secret download \
  --vault-name kv-portalxm-prb-01 \
  --name portalxm-prb-xm-com-co \
  --file portalxm-prb.raw

#1. Generate key
openssl genrsa -out tls.key 2048
#2. Generate cert
openssl req -x509 -new -nodes \
  -key tls.key \
  -subj "/CN=your-domain.com" \
  -days 365 \
  -out tls.crt
  #3. Create Kubernetes secret
  kubectl create secret tls tls-selfsigned \
  --cert=tls.crt \
  --key=tls.key \
  -n <namespace>
