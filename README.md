visit my Medium article for a leaner explanation
https://medium.com/@datatomas/aks-storage-demystified-inline-volumes-pv-pvc-file-shares-ingress-explained-clearly-7696645b257d
## Prerequisites / Tools
<img width="821" height="1390" alt="frontendxm-masked drawio (1)" src="https://github.com/user-attachments/assets/f301a101-3c38-4545-a681-c6da525abedc" />

aks-secure-storage-and-ingress/
├─ README.md
├─ manifests/
│  ├─ ns-quota.yaml                # Namespace ResourceQuota + LimitRange
│  ├─ service-account.yaml         # sa-drupal with workload identity annotations
│  ├─ secret-class-provider.yaml   # SecretProviderClass (Key Vault → k8s secret)
│  ├─ azure-files-pod.yaml         # Drupal Deployment + Azure Files + KV CSI
│  ├─ ingress-service.yaml         # ClusterIP Service (drupal-service)
│  ├─ ingress-service-backend.yaml # Ingress with host/TLS/backend rules
│  └─ dns-pod-test.yaml            # Optional DNS/debug pod
├─ scripts/
│  ├─ 01-user-assigned-identity.sh     # Create UAMI + basic wiring
│  ├─ 02-federate-credential.sh        # Create federated credential (AKS OIDC → UAMI)
│  ├─ 03-akv-generate-selfsigned-cert.sh # Self-signed cert directly in Key Vault
│  ├─ 03-local-self-signed.sh          # Local self-signed cert → tls.{crt,key} → k8s secret
│  └─ azure-files-deployment.sh        # Orchestrates full Azure Files + ingress deployment
└─ docs/
   └─ aks-pods-deployments-ingress-certificates-v2.docx  # Detailed walkthrough/design notes



**
AKS – Workload Identity, Azure Files, and TLS Ingress (Drupal example)
**
This repo shows end-to-end how to:

Configure Azure Kubernetes Service (AKS) with Azure AD Workload Identity

Mount an Azure Files share using a storage account key coming from Azure Key Vault (via Secrets Store CSI)

Expose a Drupal (or any web) workload over HTTPS using NGINX Ingress and a TLS certificate

The concrete example uses a Drupal image, but the pattern works for any web app running on AKS.

1. Prerequisites
Local tools

You’ll need on your workstation:

Azure CLI (az)

kubectl

jq – used by scripts for JSON parsing

openssl – to extract tls.crt / tls.key from a .pfx

Helm (optional) – only if you want to install ingress manually

Log in and select the right subscription:

az login
az account set --subscription "<SUBSCRIPTION_ID>"


Make sure kubectl points to your cluster:

az aks get-credentials -g <RESOURCE_GROUP> -n <AKS_NAME>
kubectl get nodes

Azure resources

You should have (or plan to create):

An AKS cluster with:

Managed identity

Workload Identity + OIDC issuer enabled

azure-keyvault-secrets-provider addon enabled (Secrets Store CSI + Azure KV provider)

An NGINX Ingress Controller (for example, in ingress-nginx)

An Azure Key Vault reachable from AKS (ideally via private endpoint)

An Azure Storage Account with an Azure Files share

A TLS certificate for your DNS name (e.g. portalxm-prb.xm.com.co) as a .pfx

2. Environment variables

All scripts assume you export core variables first. Adjust to your environment and environment name (PRB / CAL / etc.):

export SUBSCRIPTION_ID="e9ba7be7-6071-4cba-8cd0-dd3f10fdefa4"

# AKS / RG / KV / namespace
export RESOURCE_GROUP="GR_PORTALXM-PRB-01"
export AKS_NAME="aks-portalxm-prb-01"
export KV_NAME="kv-portalxm-prb-01"
export NAMESPACE="ns-portalxmdrupal"

# Workload identity
export IDENTITY_NAME="id-portaldrupalxm-prb-01"
export FEDERATED_CREDENTIAL_NAME="fc-portaldrupalxm-prb-01"

# DNS and TLS
export DOMAIN_NAME="portalxm-prb.xm.com.co"
export TLS_SECRET_NAME="drupal-portalxmprb-tls"


For CAL/QA, swap the RESOURCE_GROUP, AKS_NAME, KV_NAME, IDENTITY_NAME, etc.

3. Creating / configuring AKS

If you already have an AKS cluster with Workload Identity and the Key Vault CSI addon enabled, you can skip to section 4.

3.1 Create AKS with Workload Identity + KV addon

Example:

az group create -n "$RESOURCE_GROUP" -l eastus2

az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-addons azure-keyvault-secrets-provider \
  --node-count 3 \
  --generate-ssh-keys \
  --network-plugin azure


If the cluster already exists but is missing Workload Identity or the addon:

# Enable Workload Identity + OIDC if not already on
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --enable-oidc-issuer \
  --enable-workload-identity

# Enable Key Vault CSI addon
az aks enable-addons \
  --addons azure-keyvault-secrets-provider \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME"


Fetch credentials:

az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME"

3.2 Install NGINX ingress (if not provided)

If your cluster doesn’t already have an ingress controller:

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

4. Workload Identity wiring

We use a User Assigned Managed Identity (UAMI) that pods will impersonate via a Kubernetes ServiceAccount + OIDC federated credentials. This identity gets access to Key Vault and to the Storage Account.

4.1 Create the User Assigned Managed Identity
az identity create \
  --name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location eastus2 \
  --subscription "$SUBSCRIPTION_ID"


Grab its IDs:

export IDENTITY_CLIENT_ID=$(
  az identity show \
    --name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query clientId -o tsv
)

export IDENTITY_PRINCIPAL_ID=$(
  az identity show \
    --name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query principalId -o tsv
)

export IDENTITY_TENANT_ID=$(az account show --query tenantId -o tsv)

4.2 Create the federated identity credential

Get the OIDC issuer for the AKS cluster:

export AKS_OIDC_ISSUER=$(
  az aks show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --query "oidcIssuerProfile.issuerUrl" -o tsv
)


Create the federated credential so the sa-drupal ServiceAccount in ns-portalxmdrupal can obtain tokens as the managed identity:

az identity federated-credential create \
  --name "$FEDERATED_CREDENTIAL_NAME" \
  --identity-name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject "system:serviceaccount:${NAMESPACE}:sa-drupal" \
  --audiences "api://AzureADTokenExchange"

4.3 Grant Key Vault and Storage permissions

Key Vault (Secrets + Certificates reader):

export KV_ID=$(
  az keyvault show \
    --name "$KV_NAME" \
    --subscription "$SUBSCRIPTION_ID" \
    --query id -o tsv
)

az role assignment create \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --role "Key Vault Secrets User" \
  --scope "$KV_ID"

az role assignment create \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --role "Key Vault Certificates User" \
  --scope "$KV_ID"


Storage (access to Azure Files share):

# Storage account name usually stored in Key Vault as 'drupal-storage-name'
export STORAGE_ACCOUNT_NAME=$(
  az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name drupal-storage-name \
    --subscription "$SUBSCRIPTION_ID" \
    --query value -o tsv
)

export STORAGE_RESOURCE_ID=$(
  az storage account show \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" \
    --query id -o tsv
)

az role assignment create \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --role "Storage File Data SMB Share Contributor" \
  --scope "$STORAGE_RESOURCE_ID"


(If your Azure Policy forbids service port 80, you can still keep container targetPort: 80 and expose service port 443 only – see note in section 7.1.)

5. TLS certificates and Kubernetes secret
5.1 Extract tls.crt and tls.key from .pfx

Assuming you received portalxm-prb_xm_com_co.pfx:

# Private key
openssl pkcs12 -in portalxm-prb_xm_com_co.pfx -nocerts -nodes -out tls.key -legacy

# Certificate
openssl pkcs12 -in portalxm-prb_xm_com_co.pfx -clcerts -nokeys -out tls.crt -legacy


You should now have:

portalxm-prb_xm_com_co.pfx

tls.crt

tls.key

5.2 Create the Kubernetes TLS secret
kubectl delete secret "$TLS_SECRET_NAME" -n "$NAMESPACE" || true

kubectl create secret tls "$TLS_SECRET_NAME" \
  --cert=tls.crt \
  --key=tls.key \
  -n "$NAMESPACE"


This secret is referenced by the Ingress.

6. Repo structure

Recommended layout (matches this repo):

manifests/
  ns-quota.yaml                 # ResourceQuota + LimitRange
  service-account.yaml          # sa-drupal with WI annotations
  secret-class-provider.yaml    # SecretProviderClass (KV → k8s secret for storage key)
  azure-files-pod.yaml          # Deployment mounting Azure Files
  ingress-service.yaml          # ClusterIP Service (drupal-service)
  ingress-service-backend.yaml  # Ingress resource (drupal-ingress)
  dns-pod-test.yaml             # Optional DNS/debug pod

scripts/
  01-user-assigned-identity.sh
  02-federate-credential.sh
  03-akv-generate-selfsigned-cert.sh
  03-local-self-signed.sh
  azure-files-deployment.sh
  # plus any helpers you add

7. Applying manifests – happy-path order

From the repo root:

# 1. Namespace governance (quotas and limits)
kubectl apply -f manifests/ns-quota.yaml

# 2. ServiceAccount with Workload Identity annotations
kubectl apply -f manifests/service-account.yaml

# 3. SecretProviderClass – reads storage account name/key from Key Vault
kubectl apply -f manifests/secret-class-provider.yaml

# 4. (Optional) DNS / debug pod
kubectl apply -f manifests/dns-pod-test.yaml

# 5. Workload (Drupal) mounting Azure Files + Key Vault CSI
kubectl apply -f manifests/azure-files-pod.yaml

# 6. Service in front of the app
kubectl apply -f manifests/ingress-service.yaml

# 7. Ingress – host, TLS secret, and backend service mapping
kubectl apply -f manifests/ingress-service-backend.yaml

7.1 Key manifests (simplified)

Service (standard HTTP pattern):

apiVersion: v1
kind: Service
metadata:
  name: drupal-service
  namespace: ns-portalxmdrupal
spec:
  type: ClusterIP
  selector:
    app: drupal
  ports:
  - port: 80        # what Ingress calls
    targetPort: 80  # container port
    protocol: TCP


If an Azure Policy disallows service port 80, you can instead use:

ports:
- port: 443
  targetPort: 80


The pod still listens on 80, but the service is exposed on 443 only.

Deployment (Drupal + Azure Files + KV CSI):

apiVersion: apps/v1
kind: Deployment
metadata:
  name: drupal-deployment
  namespace: ns-portalxmdrupal
spec:
  replicas: 1
  selector:
    matchLabels:
      app: drupal
  template:
    metadata:
      labels:
        app: drupal
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: sa-drupal
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: drupal
        image: acrtransversalprbeastus2.azurecr.io/portal/xmdrupal:501534
        ports:
        - containerPort: 80
        volumeMounts:
        - name: azure
          mountPath: /opt/drupal/web/sites/default/files
        - name: kv-secrets
          mountPath: /mnt/kv-secrets
          readOnly: true
      volumes:
      - name: kv-secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: azure-file-secret-provider
      - name: azure
        csi:
          driver: file.csi.azure.com
          readOnly: false
          volumeAttributes:
            secretName: drupal-storage-key
            shareName: portaldrupal-fs


Ingress (TLS + host → service:80):

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: drupal-ingress
  namespace: ns-portalxmdrupal
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - portalxm-prb.xm.com.co
    secretName: drupal-portalxmprb-tls
  rules:
  - host: portalxm-prb.xm.com.co
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: drupal-service
            port:
              number: 80   # or 443 if you changed the Service port

8. Quick health checks
# Pods
kubectl get pods -n "$NAMESPACE"

# Azure File mount status (pod events)
kubectl describe pod -n "$NAMESPACE" -l app=drupal

# Service and endpoints
kubectl get svc -n "$NAMESPACE"
kubectl get endpointslice -n "$NAMESPACE" \
  -l kubernetes.io/service-name=drupal-service

# Ingress and TLS
kubectl get ingress -n "$NAMESPACE"
kubectl describe ingress drupal-ingress -n "$NAMESPACE"

# Check cert wired to secret
kubectl get secret "$TLS_SECRET_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -text | egrep 'Subject:|Issuer:|Not Before|Not After'

8.1 Validate mounts from inside the pod
POD=$(kubectl get pod -n "$NAMESPACE" -l app=drupal -o jsonpath='{.items[0].metadata.name}')

# Key Vault CSI content
kubectl exec -n "$NAMESPACE" "$POD" -- ls -la /mnt/kv-secrets

# Azure Files mount
kubectl exec -n "$NAMESPACE" "$POD" -- ls -la /opt/drupal/web/sites/default/files

# Test write access to Azure Files
kubectl exec -n "$NAMESPACE" "$POD" -- sh -c \
  "touch /opt/drupal/web/sites/default/files/test-file.txt && ls -la /opt/drupal/web/sites/default/files"

8.2 Test Ingress endpoint
# Get ingress IP/hostname
kubectl get ingress drupal-ingress -n "$NAMESPACE" -o wide

# From your machine (assuming DNS → Ingress IP is configured)
curl -k https://"$DOMAIN_NAME" -v

9. Troubleshooting tips

Some common failure points and what to check:

ImagePullBackOff

ACR not allowed / wrong credentials:

Ensure AKS node identity or a dedicated pull identity has AcrPull on the ACR

Check image name and tag

kubectl describe pod -n "$NAMESPACE" -l app=drupal
kubectl logs -n "$NAMESPACE" -l app=drupal --tail=50 --previous

Volume / Azure Files mount errors

Verify drupal-storage-key secret exists with keys:

azurestorageaccountname

azurestorageaccountkey

Confirm portaldrupal-fs share exists in the storage account

Check events for the pod:

kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20

Secrets Store CSI issues
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
kubectl get secretproviderclass -n "$NAMESPACE"
kubectl describe secretproviderclass azure-file-secret-provider -n "$NAMESPACE"

Workload Identity not working

ServiceAccount annotations present?

Pod has azure.workload.identity/use: "true" label?

Federated credential subject exactly:
system:serviceaccount:ns-portalxmdrupal:sa-drupal?

kubectl get sa sa-drupal -n "$NAMESPACE" -o yaml
kubectl exec -n "$NAMESPACE" "$POD" -- env | grep AZURE_

10. Summary

This setup gives you:

Managed identity–based access from your pods to Key Vault and Storage (no secrets in YAML)

Azure Files mounted directly into your Drupal container for persistent content

TLS-terminated HTTPS at the NGINX Ingress level, with certificates managed via Key Vault or provided as .pfx

A clean, repeatable deployment flow using scripts + Kubernetes manifests in this repo






