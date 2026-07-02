# Troubleshooting

## Elasticsearch preso em `Pending` ou `unknown`

```bash
kubectl -n elastic describe pod elasticsearch-es-default-0 | tail -30
kubectl -n elastic get events --sort-by=.lastTimestamp | tail -20
```

Causas comuns:

- **Memória insuficiente** — reduza `es_memory` em `group_vars/all.yml` (mínimo prático: `1Gi`) e reaplique com `--tags elastic`;
- **PVC sem bind** — confira `kubectl get pvc -n elastic` e se a StorageClass `local-path` existe (`kubectl get sc`);
- **`vm.max_map_count` baixo** — `sysctl vm.max_map_count` deve retornar `262144` (fase `prereqs`).

## Kibana `red` ou reiniciando

```bash
kubectl -n elastic logs deploy/kibana-kb | tail -30
```

Normalmente é o Elasticsearch ainda inicializando — o Kibana estabiliza quando o ES fica `green`. Verifique também memória disponível no host.

## Filebeat não entrega logs

```bash
kubectl -n elastic logs ds/filebeat-beat-filebeat | grep -iE "error|connect" | tail
```

- `connection refused` para `logstash-ls-beats:5044` → confirme o Service:
  `kubectl -n elastic get svc logstash-ls-beats` e os logs do Logstash:
  `kubectl -n elastic logs sts/logstash-ls | tail`;
- Sem eventos de pods → confira o RBAC (`kubectl auth can-i list pods --as=system:serviceaccount:elastic:beats`).

## Metricbeat sem métricas do kubelet

```bash
kubectl -n elastic logs ds/metricbeat-beat-metricbeat | grep -i kubelet | tail
```

O módulo `kubernetes` usa `https://${NODE_IP}:10250` com `ssl.verification_mode: none`. Se houver recusa de conexão, valide que a porta 10250 responde no host: `sudo ss -tlnp | grep 10250`.

## Sem dados do módulo nginx (stubstatus)

- As *annotations* de hints estão no template do Deployment (`co.elastic.metrics/*`);
- Teste o endpoint dentro do cluster:

```bash
kubectl -n apps exec deploy/nginx-chaos -- curl -s http://nginx-web/nginx_status
```

## Painel do nginx-chaos com falhas de proxy (502)

O proxy resolve `nginx-web.apps.svc.cluster.local` via CoreDNS (`10.43.0.10`). Se o seu cluster usa outro IP de DNS:

```bash
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'
```

Atualize `cluster_dns` em `group_vars/all.yml` e reaplique com `--tags apps`.

## NodePort inacessível de outra máquina

- Confirme que o firewalld está parado (`systemctl status firewalld`) ou libere as portas 30080/30090/30561;
- Teste local primeiro: `curl http://localhost:30080/ok`;
- De fora, use o IP do host (`ip -4 addr show`), não `localhost`.

## Logs com a tag `nginx_grok_failure`

O formato de log difere do *combined* padrão. Ajuste o pattern no `logstash.yml.j2` e reaplique com `--tags elastic` (o ECK faz o reload do pipeline).

## Reset completo

```bash
ansible-playbook destroy.yml -K -e destroy_scope=full
ansible-playbook site.yml -K
```
