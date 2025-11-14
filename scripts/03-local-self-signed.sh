

###############################################
# OPTION B – Generate a local self-signed cert
###############################################

#1. Generate private key
openssl genrsa -out tls.key 2048

#2. Generate self-signed certificate
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
