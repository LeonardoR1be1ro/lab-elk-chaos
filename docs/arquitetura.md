# Arquitetura do laboratório

## Visão geral

Um único host Fedora 44 executa um cluster k3s de nó único. O operador **ECK** gerencia o ciclo de vida do Elastic Stack (TLS interno, usuários, upgrades e reload de configuração). As aplicações de teste vivem no namespace `apps`; o stack de observabilidade, no namespace `elastic`.

## Componentes

### namespace `elastic`

| Recurso | Tipo (CR do ECK) | Função |
|---|---|---|
| `elasticsearch` | `Elasticsearch` (1 nó, PVC 10Gi `local-path`) | Armazenamento e busca |
| `kibana` | `Kibana` (NodePort 30561, TLS desabilitado no HTTP) | Visualização e alertas |
| `logstash` | `Logstash` (StatefulSet + Service `logstash-ls-beats:5044`) | Parse dos logs do nginx (grok) e escrita no ES |
| `filebeat` | `Beat` (DaemonSet) | Coleta de logs de contêineres via autodiscover/hints |
| `metricbeat` | `Beat` (DaemonSet, hostNetwork) | Métricas de sistema, kubelet e `stub_status` do nginx |

### namespace `apps`

| Recurso | Função |
|---|---|
| `nginx-web` (Deployment, 2 réplicas, NodePort 30080) | Alvo monitorado. Expõe `/ok`, `/erro/{404,500,503}`, `/lento` e `/nginx_status` |
| `nginx-chaos` (Deployment, NodePort 30090) | Painel web de chaos engineering; proxy `/target/*` → `nginx-web` |

## Decisões de projeto

1. **Filebeat → Logstash → Elasticsearch** (em vez de Filebeat direto no ES): mantém o Logstash como ponto central de parse/enriquecimento, espelhando arquiteturas comuns em produção e permitindo evoluir o pipeline (mutations, drop, roteamento) sem tocar nos agentes;
2. **Hints-based autodiscover**: o `nginx-web` declara nas *annotations* como deve ser monitorado (`co.elastic.metrics/*`) — o padrão escala para novas aplicações sem alterar os Beats;
3. **Proxy same-origin no nginx-chaos**: o navegador fala apenas com o `nginx-chaos`; o proxy `/target/*` elimina CORS e faz o tráfego de caos atravessar a rede do cluster, aparecendo nos logs do `nginx-web` com origem interna;
4. **Resolver dinâmico no proxy**: `resolver 10.43.0.10 valid=10s` + variável no `proxy_pass` evita cache eterno de DNS caso o Service seja recriado;
5. **Índice `lab-nginx-*`** (e não `logs-*`): evita colisão com os index templates/data streams nativos do Elasticsearch 9.x;
6. **Senhas e TLS por conta do ECK**: nenhum segredo em arquivos do repositório; Logstash e Beats recebem credenciais via `elasticsearchRef`/variáveis injetadas pelo operador.

## Portas

| Porta | Serviço | Escopo |
|---|---|---|
| 6443 | API do Kubernetes | host |
| 30561 | Kibana | NodePort |
| 30080 | nginx-web | NodePort |
| 30090 | nginx-chaos | NodePort |
| 5044 | Logstash (beats input) | ClusterIP |
| 9200/9300 | Elasticsearch | ClusterIP (TLS) |
| 10250 | kubelet (Metricbeat) | host |
