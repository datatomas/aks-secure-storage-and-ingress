RG="GR_PORTALXM-PRB-01"
AKS="aks-portalxm-prb-01"
NS="drupal-frontend"
UAMI_NAME="aks-portalxm-prb-01-agentpool"       # or your dedicated UAMI

CLIENT_ID=$(az identity show -g "$RG" -n "$UAMI_NAME" --query clientId -o tsv)
ISSUER=$(az aks show -g "$RG" -n "$AKS" --query 'oidcIssuerProfile.issuerUrl' -o tsv)

# apply serviceaccount.yaml after replacing the clientId
kubectl apply -f serviceaccount.yaml

az identity federated-credential create \
  --name drupal-frontend-federation \
  --identity-name "$UAMI_NAME" \
  --resource-group "$RG" \
  --issuer "$ISSUER" \
  --subject "system:serviceaccount:$NS:drupal-frontend-sa"

# Give uami share-level rbac on storage
STG_ACC="stportaldrupalprb01"
STG_SCOPE=$(az storage account show -g "$RG" -n "$STG_ACC" --query id -o tsv)

az role assignment create \
  --assignee "$CLIENT_ID" \
  --role "Storage File Data SMB Share Contributor" \
  --scope "$STG_SCOPE"


#Apply order

# once per cluster (already done, included for completeness):
az aks update -g "$RG" -n "$AKS" --enable-oidc-issuer --enable-workload-identity
az aks update -g "$RG" -n "$AKS" --enable-file-driver

# namespace first
kubectl create namespace drupal-frontend || true

# guardrails + storage + identity + app
kubectl apply -f ns_quota.yaml
kubectl apply -f pvc.yaml
# replace clientId in serviceaccount.yaml before applying:
kubectl apply -f serviceaccount.yaml
# federate SA -> UAMI and grant RBAC as shown above
kubectl apply -f deployment.yaml
