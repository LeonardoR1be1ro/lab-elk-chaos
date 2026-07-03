# Elastic Stack + Chaos Engineering Lab

Automação completa em **Ansible** para provisionar, em um único host **Fedora 44**, um cluster **Kubernetes local (k3s)** rodando o **Elastic Stack via operador ECK** — Elasticsearch, Kibana, Logstash, Filebeat e Metricbeat — monitorando um serviço `nginx-web`, além de um segundo serviço `nginx-chaos` com um **painel web de chaos engineering** para injetar tráfego, erros e latência no alvo.

```
┌──────────────────────────── Fedora 44 (k3s single node) ────────────────────────────┐
│                                                                                     │
│  namespace: apps                          namespace: elastic                        │
│  ┌───────────────┐  /target/* (proxy)     ┌──────────┐   5044   ┌──────────────┐    │
│  │  nginx-chaos  │ ─────────────────────▶ │ Filebeat │ ───────▶ │   Logstash   │    │
│  │ painel de caos│                        │(DaemonSet│  logs    │ grok nginx + │    │
│  └───────┬───────┘                        │ hints)   │          │ enriquecim.  │    │
│          │ tráfego/erros/latência         └──────────┘          └──────┬───────┘    │
│          ▼                                ┌──────────┐                 ▼            │
│  ┌───────────────┐   stub_status          │Metricbeat│ ───▶ ┌──────────────────┐    │
│  │   nginx-web   │ ◀──────────────────────│(DaemonSet│      │  Elasticsearch   │    │
│  │ alvo monitor. │   módulo nginx (hints) │ hints)   │      │  (ECK, 1 nó)     │    │
│  └───────────────┘                        └──────────┘      └────────┬─────────┘    │
│                                                                      ▼              │
│                                                             ┌──────────────────┐    │
│   NodePorts: 30080 (web) · 30090 (chaos) · 30561 (kibana)   │      Kibana      │    │
│                                                             └──────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Fluxo de dados

| Sinal | Caminho | Destino |
|---|---|---|
| Logs de acesso do nginx | Filebeat (autodiscover/hints) → **Logstash** (grok + date) | Data stream `logs-nginx.access-default` |
| Métricas de host, Kubernetes e `stub_status` do nginx | Metricbeat (DaemonSet + hints) | Data stream `metricbeat-*` |

O Logstash faz o parse dos logs de acesso (formato *combined*) com `grok`, extraindo `http.response.status_code`, `url.path`, `user_agent.original` etc., e grava no Elasticsearch com autenticação e TLS gerenciados pelo ECK.

## Componentes e versões

| Componente | Versão (padrão) | Onde alterar |
|---|---|---|
| k3s | canal `stable` | `roles/k3s` |
| ECK (operador) | `3.4.0` | `group_vars/all.yml` → `eck_version` |
| Elastic Stack | `9.4.2` | `group_vars/all.yml` → `stack_version` |
| nginx | `1.27` | `roles/nginx_apps/templates` |

> Verifique a versão mais recente do ECK em <https://www.elastic.co/downloads/elastic-cloud-kubernetes> e a matriz de compatibilidade com o Stack 9.x antes de alterar.

## Pré-requisitos

- **Fedora 44** (Server ou Workstation) com acesso `sudo`;
- **4 vCPUs / 8 GB de RAM** no mínimo (16 GB recomendado) e ~20 GB livres em disco;
- Acesso à internet (imagens de contêiner e manifestos do ECK);
- **ansible-core ≥ 2.15**:

```bash
sudo dnf install -y ansible-core git
```

- Collections utilizadas (`kubernetes.core` e `ansible.posix`):

```bash
ansible-galaxy collection install -r requirements.yml
# ou: make setup
```

## Instalação rápida (TL;DR)

```bash
git clone https://github.com/<seu-usuario>/elastic-k8s-chaos-lab.git
cd elastic-k8s-chaos-lab
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml -K        # -K pede a senha do sudo
```

Ao final, o playbook imprime as URLs de acesso e a senha do usuário `elastic`. A execução completa leva de 10 a 20 minutos, dependendo do download das imagens.

## Execução passo a passo (com validação por fase)

Cada fase possui uma *tag* própria, permitindo executar e validar incrementalmente.

### Fase 1 — Pré-requisitos do sistema

```bash
ansible-playbook site.yml -K --tags prereqs
```

Valide:

```bash
sysctl vm.max_map_count          # esperado: 262144
python3 -c "import kubernetes; print('ok')"
```

### Fase 2 — k3s

```bash
ansible-playbook site.yml -K --tags k3s
```

Valide:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes                # STATUS: Ready
kubectl get storageclass         # local-path (default)
```

### Fase 3 — Operador ECK

```bash
ansible-playbook site.yml -K --tags eck
```

Valide:

```bash
kubectl -n elastic-system get pods            # elastic-operator-0 Running
kubectl -n elastic-system logs sts/elastic-operator | tail
```

### Fase 4 — Elasticsearch, Kibana e Logstash

```bash
ansible-playbook site.yml -K --tags elastic
```

Valide (aguarde `HEALTH: yellow` ou `green` — num cluster de 1 nó, `yellow` já é saudável, pois não há um segundo nó para alocar réplicas):

```bash
kubectl -n elastic get elasticsearch,kibana,logstash
kubectl -n elastic get pods
kubectl -n elastic get svc logstash-ls-beats   # porta 5044 exposta
```

### Fase 5 — Filebeat e Metricbeat

```bash
ansible-playbook site.yml -K --tags beats
```

Valide:

```bash
kubectl -n elastic get beat                    # HEALTH: green
kubectl -n elastic logs ds/filebeat-beat-filebeat | tail
kubectl -n elastic logs ds/metricbeat-beat-metricbeat | tail
```

### Fase 6 — nginx-web e nginx-chaos

```bash
ansible-playbook site.yml -K --tags apps
```

Valide:

```bash
kubectl -n apps get pods,svc
curl -s http://localhost:30080/ok             # nginx-web: OK
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/erro/500   # 500
curl -s http://localhost:30090/ | head -5     # painel de caos
```

## Acessando o ambiente

| Serviço | URL | Observação |
|---|---|---|
| Kibana | `http://<IP-do-host>:30561` | usuário `elastic` |
| nginx-web | `http://<IP-do-host>:30080` | alvo monitorado |
| nginx-chaos | `http://<IP-do-host>:30090` | painel de injeção de falhas |

Senha do usuário `elastic`:

```bash
kubectl -n elastic get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d ; echo
# ou: make password
```

## Configurando os data views no Kibana

1. Acesse **Kibana → Stack Management → Data Views → Create data view**;
2. Crie o data view **`logs-nginx.access-*`** (timestamp: `@timestamp`) — logs do nginx parseados pelo Logstash;
3. Crie o data view **`metricbeat-*`** — métricas de host, Kubernetes e `stub_status` do nginx;
4. Em **Discover**, selecione `logs-nginx.access-*` e filtre por `kubernetes.labels.app : "nginx-web"`.

Consultas KQL úteis e sugestões de visualizações e alertas estão em [`docs/kibana.md`](docs/kibana.md).

## Roteiro de chaos engineering

Abra `http://<IP-do-host>:30090` e execute os cenários. Todas as requisições passam pelo proxy `/target/*` do `nginx-chaos` e chegam ao `nginx-web` pela rede interna do cluster.

| Cenário | O que injeta | O que observar no Kibana |
|---|---|---|
| Tráfego normal | GETs em `/ok` e `/` | Baseline de RPS e latência em `logs-nginx.access-*` |
| Rajada de 404 | Rotas inexistentes | `http.response.status_code : 404` subindo |
| Erros 500 | `/erro/500` | Taxa de erro 5xx — bom gatilho para alertas |
| Indisponível 503 | `/erro/503` | Simulação de outage / circuito aberto |
| Latência alta | `/lento` (2 KB/s) | Conexões ativas no `stub_status` (metricbeat) |
| Caos total | Mistura ponderada | Comportamento sob falhas combinadas |

Sugestão de experimento completo (hipótese → injeção → observação → aprendizado):

1. **Hipótese**: "com 20 rps de erros 500, um alerta de taxa de erro > 10% dispara em até 2 minutos";
2. Crie o alerta no Kibana (**Observability → Alerts**, ou regra de *threshold* sobre `logs-nginx.access-*`);
3. Rode o cenário **Erros 500** com 20 rps por 5 minutos;
4. Verifique o disparo, o tempo de detecção e documente o resultado.

## Estrutura do repositório

```
elastic-k8s-chaos-lab/
├── ansible.cfg
├── site.yml                  # playbook principal (tags por fase)
├── destroy.yml               # remoção (workloads ou k3s completo)
├── requirements.yml           # collections Ansible
├── Makefile                   # atalhos: deploy, status, password, destroy
├── inventory/hosts.ini        # localhost (connection=local)
├── group_vars/all.yml         # versões, namespaces, NodePorts, recursos
├── roles/
│   ├── prereqs/               # pacotes, sysctl, firewalld
│   ├── k3s/                   # instalação do k3s single node
│   ├── eck_operator/          # CRDs + operador ECK
│   ├── elastic_stack/         # Elasticsearch, Kibana, Logstash (CRs)
│   ├── beats/                 # RBAC, Filebeat (→Logstash), Metricbeat (→ES)
│   └── nginx_apps/            # nginx-web (alvo) e nginx-chaos (painel)
└── docs/                      # arquitetura, kibana, troubleshooting, GitHub
```

## Personalização

Tudo é parametrizado em [`group_vars/all.yml`](group_vars/all.yml): versões do Stack e do ECK, namespaces, NodePorts, memória/armazenamento do Elasticsearch e o IP do CoreDNS. Ajuste antes da primeira execução — trocar `stack_version` depois dispara upgrade orquestrado pelo ECK.

## Troubleshooting

Todos os problemas encontrados e corrigidos durante o desenvolvimento deste lab — de erros de configuração do Ansible a *race conditions* do operador ECK, permissões do Elasticsearch, SELinux, rate limit do Docker Hub e mais — estão documentados e organizados por camada em [`docs/troubleshooting.md`](docs/troubleshooting.md). Antes do primeiro deploy, também vale rodar `docs/pre-pull-imagens.sh` para baixar todas as imagens com antecedência e evitar timeouts de rollout.

## Limpeza

```bash
# Remove apenas os workloads (mantém o k3s)
ansible-playbook destroy.yml -K

# Remove tudo, inclusive o k3s
ansible-playbook destroy.yml -K -e destroy_scope=full
```

> O `.gitignore` já impede o versionamento de kubeconfigs, certificados e segredos. **Nunca** faça commit da senha do `elastic` ou do arquivo `k3s.yaml`.

## Licença

[MIT](LICENSE).
