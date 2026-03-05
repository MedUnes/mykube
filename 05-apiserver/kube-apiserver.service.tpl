[Unit]
Description=Kubernetes API Server
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
After=network.target etcd.service
Requires=etcd.service

[Service]
ExecStart=/usr/local/bin/kube-apiserver \
  --advertise-address=${INTERNAL_IP} \
  --allow-privileged=true \
  --authorization-mode=Node,RBAC \
  --client-ca-file=/etc/kubernetes/pki/ca.pem \
  --enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota,NodeRestriction \
  --etcd-cafile=/etc/etcd/ca.pem \
  --etcd-certfile=/etc/etcd/etcd.pem \
  --etcd-keyfile=/etc/etcd/etcd-key.pem \
  --etcd-servers=https://127.0.0.1:2379 \
  --kubelet-certificate-authority=/etc/kubernetes/pki/ca.pem \
  --kubelet-client-certificate=/etc/kubernetes/pki/kubernetes.pem \
  --kubelet-client-key=/etc/kubernetes/pki/kubernetes-key.pem \
  --runtime-config=api/all=true \
  --service-account-issuer=https://${INTERNAL_IP}:6443 \
  --service-account-key-file=/etc/kubernetes/pki/service-account.pem \
  --service-account-signing-key-file=/etc/kubernetes/pki/service-account-key.pem \
  --service-cluster-ip-range=10.96.0.0/24 \
  --tls-cert-file=/etc/kubernetes/pki/kubernetes.pem \
  --tls-private-key-file=/etc/kubernetes/pki/kubernetes-key.pem \
  --requestheader-allowed-names="" \
  --v=2
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target