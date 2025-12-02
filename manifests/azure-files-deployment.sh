apiVersion: apps/v1
kind: Deployment
metadata:
  name: drupal-deployment
  namespace: ns-portaldrupal
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
        image: acrtransversalprbeastus2.azurecr.io/portal/xmdrupal:4999
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
