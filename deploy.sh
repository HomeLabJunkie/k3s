#!/bin/bash
set -e

# load secrets
if [ ! -f ~/k3s/.secrets ]; then
  echo "ERROR: ~/k3s/.secrets not found. Create it with RANCHER_BOOTSTRAP_PASSWORD, RANCHER_ADMIN_PASSWORD, RANCHER_ADMIN_USER"
  exit 1
fi
source ~/k3s/.secrets

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

echo "==> Waiting for Rancher to be fully ready..."
kubectl -n cattle-system rollout status deployment/rancher --timeout=300s
sleep 30

echo "==> Configuring Rancher admin credentials..."
# get bootstrap token
RANCHER_URL="https://rancher.jeffriffle.com"

LOGIN_TOKEN=$(curl -sk -X POST \
  "${RANCHER_URL}/v3-public/localProviders/local?action=login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

if [ -z "$LOGIN_TOKEN" ]; then
  echo "WARNING: Could not get Rancher login token - set admin password manually"
else
  # set permanent password
  curl -sk -X POST \
    "${RANCHER_URL}/v3/users?action=changepassword" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"currentPassword\":\"${RANCHER_BOOTSTRAP_PASSWORD}\",\"newPassword\":\"${RANCHER_ADMIN_PASSWORD}\"}"

  # set server URL
  curl -sk -X PUT \
    "${RANCHER_URL}/v3/settings/server-url" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"value\":\"${RANCHER_URL}\"}"

  echo "==> Rancher admin credentials configured"
fi

echo "==> Cluster status:"
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed

echo ""
echo "==> Done! Rancher available at https://rancher.jeffriffle.com"
echo "    Login: ${RANCHER_ADMIN_USER} / ${RANCHER_ADMIN_PASSWORD}"
