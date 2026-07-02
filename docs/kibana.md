# Guia do Kibana — data views, consultas e alertas

## 1. Data views

| Data view | Índice/pattern | Conteúdo |
|---|---|---|
| `lab-nginx-*` | `lab-nginx-YYYY.MM.dd` | Logs de acesso do nginx parseados pelo Logstash |
| `metricbeat-*` | data stream do Metricbeat | Métricas de host, Kubernetes e `stub_status` |

Criação: **Stack Management → Data Views → Create data view**, usando `@timestamp` como campo de tempo.

## 2. Campos principais em `lab-nginx-*`

Extraídos pelo `grok` no pipeline do Logstash (`roles/elastic_stack/templates/logstash.yml.j2`):

| Campo | Exemplo | Uso |
|---|---|---|
| `http.response.status_code` | `500` | Taxa de erro, alertas |
| `http.request.method` | `GET` | Perfil de tráfego |
| `url.path` | `/erro/500` | Rotas com falha |
| `nginx.remote_ip` | `10.42.0.15` | Origem (pods do cluster) |
| `user_agent.original` | `Mozilla/5.0…` | Diferenciação de clientes |
| `kubernetes.labels.app` | `nginx-web` | Filtrar o alvo |
| `tags: nginx_grok_failure` | — | Linhas que não casaram com o grok |

## 3. Consultas KQL úteis (Discover)

```text
# Apenas o alvo monitorado
kubernetes.labels.app : "nginx-web"

# Erros de servidor
kubernetes.labels.app : "nginx-web" and http.response.status_code >= 500

# Rajada de 404 (cenário de caos)
http.response.status_code : 404 and url.path : "/rota-que-nao-existe"

# Tráfego vindo do painel de caos (header adicionado pelo proxy)
message : "*X-Chaos-Lab*"

# Falhas de parse (revisar o grok)
tags : "nginx_grok_failure"
```

## 4. Visualizações sugeridas (Lens)

1. **Taxa de erro (%)** — fórmula:
   `count(kql='http.response.status_code >= 400') / count() * 100`
   sobre `lab-nginx-*`, quebrado por `kubernetes.labels.app`;
2. **RPS por classe de status** — *Bar vertical stacked*, eixo X `@timestamp` (intervalo 10s), quebra por `http.response.status_code` (top 5);
3. **Top rotas com erro** — *Table*, `url.path` filtrado por `status_code >= 400`;
4. **Conexões ativas do nginx** — em `metricbeat-*`, campo `nginx.stubstatus.active`, média por `kubernetes.pod.name`;
5. **Saúde do nó** — `system.cpu.total.norm.pct`, `system.memory.actual.used.pct`, `kubernetes.pod.cpu.usage.node.pct`.

## 5. Alertas sugeridos

| Regra | Condição | Cenário que dispara |
|---|---|---|
| Taxa de 5xx | > 10% em 2 min (custom threshold sobre `lab-nginx-*`) | Erros 500 / Caos total |
| Volume de 404 | count > 100 em 1 min com `status_code: 404` | Rajada de 404 |
| Indisponibilidade | count > 50 de `status_code: 503` em 1 min | Indisponível 503 |
| CPU do nó | `system.cpu.total.norm.pct > 0.9` por 5 min | Carga alta sustentada |

Crie em **Observability → Alerts → Manage Rules**, com o *connector* de sua preferência (para lab, o próprio índice de ações ou server log).

## 6. Validando o pipeline de ponta a ponta

```bash
# 1. Gere tráfego direto
for i in $(seq 1 50); do curl -s -o /dev/null http://localhost:30080/erro/500; done

# 2. Confirme a chegada no Elasticsearch
PASS=$(kubectl -n elastic get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n elastic exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:${PASS}" "https://localhost:9200/lab-nginx-*/_count"

# 3. No Discover, filtre: http.response.status_code : 500
```
