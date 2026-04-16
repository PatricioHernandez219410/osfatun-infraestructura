# Error al aplicar cloudnativepg.yaml — Webhook timeout

## Error

```
Error from server (InternalError): error when creating "cloudnativepg.yaml":
Internal error occurred: failed calling webhook "mcluster.cnpg.io":
failed to call webhook: Post "https://cnpg-webhook-service.cnpg-system.svc:443/...": context deadline exceeded
```

## Causa raíz

Dos problemas combinados en AWS Lightsail con Ubuntu 24.04:

1. **iptables en modo `nf_tables`:** Ubuntu 24.04 usa `nf_tables` por defecto, pero K3s (kube-proxy) genera reglas para `iptables-legacy`. Esto provoca que las reglas de enrutamiento de ClusterIPs no funcionen correctamente.

2. **Hairpin NAT:** El nodo maestro no puede alcanzar su propia IP pública desde adentro de la instancia. Como el endpoint del servicio `kubernetes` apunta a la IP pública del master, cualquier tráfico interno hacia ClusterIPs (como el webhook de CloudNativePG o CoreDNS) falla con timeout.

Síntomas observados:
- CoreDNS no podía resolver nombres internos (`nslookup` devolvía "connection timed out; no servers could be reached")
- Logs de CoreDNS mostraban `dial tcp 10.43.0.1:443: i/o timeout`
- `curl -k https://10.43.0.1:443/version` devolvía timeout en el master pero funcionaba en los workers

## Solución

### 1. Cambiar iptables a modo legacy (en todos los nodos)

```bash
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
systemctl restart k3s        # en el master
systemctl restart k3s-agent  # en los workers
```

### 2. Agregar la IP pública al loopback del master

```bash
ip addr add <IP_PUBLICA_MASTER>/32 dev lo
```

Para hacerlo persistente:

```bash
cat <<EOF > /etc/systemd/system/loopback-public-ip.service
[Unit]
Description=Add public IP to loopback for K3s hairpin NAT
Before=k3s.service
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip addr add <IP_PUBLICA_MASTER>/32 dev lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable loopback-public-ip.service
```

### Verificación

```bash
curl -k --max-time 5 https://10.43.0.1:443/version
# Debe devolver un JSON con la versión de Kubernetes
```


------------------------------------------------------------------------

## Solución "crota":

```bash
% kubectl patch validatingwebhookconfiguration cnpg-validating-webhook-configuration -p '{"webhooks": [{"name": "vcluster.cnpg.io","failurePolicy": "Ignore"}]}'
% kubectl patch mutatingwebhookconfiguration cnpg-mutating-webhook-configuration -p '{"webhooks": [{"name": "mcluster.cnpg.io","failurePolicy": "Ignore"}]}'
```

Despues volver al apply -f cloudnativepg.yaml