#!/bin/bash
ansible-playbook -i inventory/k3s-ansible/hosts.ini site.yml "$@"

echo "==> Updating kubeconfig..."
cp ~/k3s/kubeconfig ~/.kube/config
chmod 600 ~/.kube/config
sed -i 's|https://127.0.0.1:6443|https://192.168.1.216:6443|' ~/.kube/config

echo "==> Cluster status:"
kubectl get nodes
