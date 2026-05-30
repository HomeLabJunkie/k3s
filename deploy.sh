#!/bin/bash
set -e

# decrypt secrets
if [ -f ~/k3s/.secrets.enc ]; then
  eval $(sops --decrypt ~/k3s/.secrets.enc | sed 's/^/export /')
elif [ -f ~/k3s/.secrets ]; then
  source ~/k3s/.secrets
else
  echo "ERROR: No secrets file found"
  exit 1
fi

echo "==> Running Ansible playbook..."
ansible-playbook -i inventory/k3s-ansible/hosts.ini site.yml "$@"

echo "==> Updating kubeconfig..."
cp ~/k3s/kubeconfig ~/.kube/config
chmod 600 ~/.kube/config
sed -i 's|https://127.0.0.1:6443|https://192.168.1.216:6443|' ~/.kube/config

echo "==> Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "==> Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout=300s

echo "==> Installing Traefik..."
helm repo add traefik https://traefik.github.io/charts --force-update
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --values ~/k3s/traefik-values.yaml \
  --wait --timeout=300s

echo "==> Installing Rancher..."
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update
helm upgrade --install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.jeffriffle.com \
  --set ingress.tls.source=letsEncrypt \
  --set ingress.ingressClassName=traefik \
  --set letsEncrypt.email=jeff@jeffriffle.com \
  --set letsEncrypt.ingress.class=traefik \
  --set replicas=2 \
  --set bootstrapPassword=${RANCHER_BOOTSTRAP_PASSWORD} \
  --wait --timeout=600s

echo "==> Setting up Cloudflare secrets for cert-manager..."
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=${CLOUDFLARE_API_TOKEN} \
  --namespace cert-manager \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating ClusterIssuer..."
kubectl apply -f ~/k3s/clusterissuer-letsencrypt.yaml

echo "==> Deploying Cloudflare tunnel..."
kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic tunnel-token \
  --from-literal=token=${CLOUDFLARE_TUNNEL_TOKEN} \
  --namespace cloudflared \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ~/k3s/cloudflared.yaml
kubectl -n cloudflared rollout status deployment/cloudflared --timeout=120s

echo "==> Configuring Rancher admin credentials..."
kubectl port-forward -n cattle-system svc/rancher 8443:443 &>/dev/null &
PF_PID=$!
sleep 10

# read actual bootstrap password from cluster secret (handles both fresh install and upgrade)
ACTUAL_BOOTSTRAP=$(kubectl get secret --namespace cattle-system bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null \
  || echo "${RANCHER_BOOTSTRAP_PASSWORD}")

LOGIN_TOKEN=""
for i in $(seq 1 20); do
  LOGIN_TOKEN=$(curl -sk -X POST \
    "https://localhost:8443/v3-public/localProviders/local?action=login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${ACTUAL_BOOTSTRAP}\"}" \
    2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null \
    || true)
  if [ -n "$LOGIN_TOKEN" ]; then
    echo "  Rancher API ready"
    break
  fi
  echo "  waiting for Rancher API... ($i/20)"
  sleep 15
done

if [ -n "$LOGIN_TOKEN" ]; then
  curl -sk -X POST \
    "https://localhost:8443/v3/users?action=changepassword" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"currentPassword\":\"${ACTUAL_BOOTSTRAP}\",\"newPassword\":\"${RANCHER_ADMIN_PASSWORD}\"}" \
    >/dev/null
  curl -sk -X PUT \
    "https://localhost:8443/v3/settings/server-url" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"value\":\"https://rancher.jeffriffle.com\"}" \
    >/dev/null
  echo "==> Rancher admin credentials configured successfully"
else
  echo "WARNING: Could not configure Rancher credentials - set manually"
fi

kill $PF_PID 2>/dev/null || true

echo "==> Cluster status:"
kubectl get nodes
echo ""
echo "==> Done!"
echo "    Rancher: https://rancher.jeffriffle.com"
echo "    Login:   ${RANCHER_ADMIN_USER} / ${RANCHER_ADMIN_PASSWORD}"
