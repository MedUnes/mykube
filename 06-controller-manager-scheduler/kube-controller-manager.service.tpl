[Unit]
Description=Kubernetes Controller Manager
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
After=network.target kube-apiserver.service
Requires=kube-apiserver.service

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
  --kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig \
  --cluster-cidr=10.200.0.0/16 \
  --service-cluster-ip-range=10.96.0.0/24 \
  --cluster-name=kubernetes \
  --cluster-signing-cert-file=/etc/kubernetes/pki/ca.pem \
  --cluster-signing-key-file=/etc/kubernetes/pki/ca-key.pem \
  --root-ca-file=/etc/kubernetes/pki/ca.pem \
  --service-account-private-key-file=/etc/kubernetes/pki/service-account-key.pem \
  --leader-elect=true \
  --use-service-account-credentials=true \
  --allocate-node-cidrs=true \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target