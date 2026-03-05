[Unit]
Description=Kubernetes Kubelet
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/etc/kubernetes/kubelet-config.yaml \
  --kubeconfig=/etc/kubernetes/kubelet.kubeconfig \
  --node-ip=${INTERNAL_IP} \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
