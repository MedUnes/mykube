# nginx Ingress DaemonSet
#
# hostNetwork: true  — nginx binds to the real node IP on ports 80/443.
# dnsPolicy: ClusterFirstWithHostNet — CRITICAL. Without this, hostNetwork
# pods use the node /etc/resolv.conf and cannot resolve cluster.local names.
# With it, CoreDNS at 10.96.0.10 is used — service names resolve correctly.
#
# Pinned to the ingress node via nodeSelector ingress=true.
# Label is applied by bootstrap-ingress.sh.
#
# Cert Secrets are mounted individually — new-site.sh patches this DaemonSet
# to add a volume + volumeMount for each domain cert.
#
# Variable substituted by bootstrap-ingress.sh:
#   INGRESS_NODE — node name, e.g. worker-node-1
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-ingress
  namespace: ingress
  annotations:
    ingress.mykube/cert-domains: ""
spec:
  selector:
    matchLabels:
      app: nginx-ingress
  template:
    metadata:
      labels:
        app: nginx-ingress
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        ingress: "true"
      tolerations:
      - operator: Exists
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - name: http
          containerPort: 80
          hostPort: 80
          protocol: TCP
        - name: https
          containerPort: 443
          hostPort: 443
          protocol: TCP
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
        - name: nginx-sites
          mountPath: /etc/nginx/sites
          readOnly: true
        - name: nginx-logs
          mountPath: /var/log/nginx
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 256Mi
        livenessProbe:
          httpGet:
            path: /healthz
            port: 80
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 30
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /healthz
            port: 80
            scheme: HTTP
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 3
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
      - name: nginx-sites
        configMap:
          name: nginx-sites
      - name: nginx-logs
        emptyDir: {}
