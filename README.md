visit my Medium article for a leaner explanation
https://medium.com/@datatomas/aks-storage-demystified-inline-volumes-pv-pvc-file-shares-ingress-explained-clearly-7696645b257d
## Prerequisites / Tools
<img width="821" height="1390" alt="frontendxm-masked drawio (1)" src="https://github.com/user-attachments/assets/f301a101-3c38-4545-a681-c6da525abedc" />

To use this repo you need:

- **Azure CLI**
  - Logged in: `az login`
  - Right subscription selected:  
    `az account set --subscription "<SUBSCRIPTION_ID>"`
- **kubectl** pointing to your AKS cluster:  
  `az aks get-credentials -g <RG> -n <AKS_NAME>`
- **jq** – used by the certificate scripts to tweak Key Vault policies.
- **openssl** – used to extract `.key` / `.crt` from PFX.
- An existing **AKS cluster** with:
  - **Azure Workload Identity** enabled
  - **Secrets Store CSI + Azure Key Vault provider** installed
  - **NGINX ingress controller** running (e.g. `ingress-nginx` namespace)
- An **Azure Key Vault** reachable from AKS (ideally via private endpoint).

---

## 🔧 Required Environment Variables

All scripts assume you export a few variables first (adapt these to your env):

```bash
export SUBSCRIPTION_ID="xxxx-xxxx-xxxx"
export RESOURCE_GROUP="gr-front-app-prb-01"
export AKS_NAME="aks-front-app-prb-01"
export KV_NAME="kv-front-app-prb-01"
export NAMESPACE="ns-front-app"
export IDENTITY_NAME="id-portaldrupalxm-prb-01"
export FEDERATED_CREDENTIAL_NAME="fc-front-app-portaldrupalxm-prb-01"
export DOMAIN_NAME="front-app-prb.xm.com.co"
🚀 Quick Deployment Flow
This is the happy-path to get storage + ingress + TLS working using this repo.

1️⃣ Create identity + workload identity wiring
From /scripts:

bash
Copy code
# 1. Create User Assigned Managed Identity
./01-user-assigned-identity.sh

# 2. Create Federated Credential (AKS OIDC → Managed Identity)
./02-federate-credential.sh
2️⃣ Generate certificate and create TLS secret
Option A – Self-signed in Key Vault (recommended for your scenario):

bash
Copy code
./03-akv-generate-selfsigned-cert.sh
# This will end by creating a secret like: front-app-prb-tls in your namespace
Option B – Given a PFX from someone else:

bash
Copy code
./03-local-self-signed.sh
# Uses: openssl … → tls.key / tls.crt → kubectl create secret tls ...
Make sure the Ingress TLS section points to that secret name.

📦 Apply Kubernetes Manifests (order)
From the repo root:

bash
Copy code
# 1. Namespace governance (quota / limits)
kubectl apply -f manifests/ns-quota.yaml

# 2. ServiceAccount with labels/annotations for Workload Identity
kubectl apply -f manifests/service-account.yaml

# 3. SecretProviderClass for Azure Files (Key Vault → K8s Secret)
kubectl apply -f manifests/secret-class-provider.yaml

# 4. Test DNS pod (optional, for network debugging)
kubectl apply -f manifests/dns-pod-test.yaml

# 5. Workload pod that mounts Azure File share
kubectl apply -f manifests/azure-files-pod.yaml

# 6. Service that fronts the pod
kubectl apply -f manifests/ingress-service.yaml

# 7. Ingress (entry point) with TLS + host + path rules
kubectl apply -f manifests/ingress-entry-point.yaml
✅ Quick Health Checks
bash
Copy code
# Pods
kubectl get pods -n $NAMESPACE

# Azure File mount status (pod events)
kubectl describe pod drup-fs-test -n $NAMESPACE

# Service and endpoints
kubectl get svc -n $NAMESPACE
kubectl get endpointslice -l kubernetes.io/service-name=drupal-service -n $NAMESPACE

# Ingress and TLS
kubectl get ingress -n $NAMESPACE
kubectl describe ingress drupal-ingress -n $NAMESPACE

# Check cert wired to secret
kubectl get secret drupal-front-appprb-tls -n $NAMESPACE \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text \
  | egrep 'Subject:|Issuer:|Not Before|Not After'
That’s it — with these bits in the README you have:

Tools you need 🧰

Env vars you must set 🧪

Exact order to run scripts & apply manifests 🧱

Quick commands to verify everything 🔍

If you paste this into your README and want me to do a final pass over the whole file as one piece, just drop the current README content here and I’ll polish it end-to-end.







