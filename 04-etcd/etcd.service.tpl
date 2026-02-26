[Unit]
Description=etcd: reliable distributed key-value store
Documentation=https://github.com/etcd-io/etcd
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \
--name ${ETCD_NAME} \
--data-dir /var/lib/etcd \
--listen-peer-urls https://${INTERNAL_IP}:2380 \
--listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \
--initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \
--advertise-client-urls https://${INTERNAL_IP}:2379 \
--initial-cluster ${ETCD_NAME}=https://${INTERNAL_IP}:2380 \
--initial-cluster-state new \
--initial-cluster-token etcd-cluster-k8s \
--cert-file=/etc/etcd/etcd.pem \
--key-file=/etc/etcd/etcd-key.pem \
--trusted-ca-file=/etc/etcd/ca.pem \
--peer-cert-file=/etc/etcd/etcd.pem \
--peer-key-file=/etc/etcd/etcd-key.pem \
--peer-trusted-ca-file=/etc/etcd/ca.pem \
--peer-client-cert-auth \
--client-cert-auth
Restart=on-failure
RestartSec=5
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target