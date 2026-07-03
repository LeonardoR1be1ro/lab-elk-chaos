# Manual — Monitoramento com Dashboard no Kibana

Guia passo a passo para configurar o Kibana do zero e montar um dashboard operacional para acompanhar o `nginx-web` durante os cenários de chaos engineering do `nginx-chaos`.

Pré-requisito: o ambiente já provisionado (`ansible-playbook site.yml -K`) com Elasticsearch, Kibana, Logstash, Filebeat e Metricbeat em `green`/`Running`.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n elastic get elasticsearch,kibana,logstash,beat
```

---

## 1. Acesso ao Kibana

```bash
kubectl -n elastic get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d ; echo
```

Acesse `http://<IP-do-host>:30561`, usuário `elastic`, senha do comando acima.

Na tela inicial, se aparecer o assistente de boas-vindas, escolha **Explore on my own**.

---

## 2. Criar os Data Views

O ambiente grava em dois índices/streams diferentes — um para cada Data View.

1. Menu ☰ (canto superior esquerdo) → **Stack Management** → **Data Views**;
2. **Create data view**:
   - **Name**: `logs-nginx.access-*`
   - **Index pattern**: `logs-nginx.access-*`
   - **Timestamp field**: `@timestamp`
   - **Save data view to Kibana**;
3. Repita para o segundo:
   - **Name**: `metricbeat-*`
   - **Index pattern**: `metricbeat-*`
   - **Timestamp field**: `@timestamp`
   - **Save data view to Kibana**.

> Se `logs-nginx.access-*` não retornar nenhum campo na criação, é sinal de que ainda não há documentos indexados — gere tráfego primeiro (seção 3) e recarregue a página de criação do data view.

---

## 3. Gerar tráfego de teste

Antes de montar visualizações, é mais fácil trabalhar com dados reais na tela. Use o painel de chaos:

1. Acesse `http://<IP-do-host>:30090`;
2. Clique no cenário **Tráfego normal**, deixe rodando (padrão: 5 rps, 60s);
3. Aguarde a barra de KPIs do próprio painel confirmar requisições sendo enviadas.

Alternativa via terminal, se preferir gerar carga sem abrir o navegador:

```bash
for i in $(seq 1 100); do curl -s -o /dev/null http://localhost:30080/ok; done
for i in $(seq 1 30);  do curl -s -o /dev/null http://localhost:30080/erro/500; done
```

---

## 4. Explorar os dados no Discover

1. Menu ☰ → **Discover**;
2. No seletor de Data View (canto superior esquerdo do painel), escolha **logs-nginx.access-***;
3. Ajuste o intervalo de tempo (canto superior direito) para **Last 15 minutes**;
4. Você deve ver documentos chegando. Confira os campos principais expandindo um documento (seta `>` à esquerda da linha):
   - `http.response.status_code`
   - `url.path`
   - `http.request.method`
   - `kubernetes.labels.app`
5. Teste filtros KQL na barra de busca:

```text
kubernetes.labels.app : "nginx-web"
```

```text
http.response.status_code >= 500
```

Se `logs-nginx.access-*` estiver vazio mesmo após gerar tráfego, veja a seção **Troubleshooting** no fim deste manual antes de continuar.

---

## 5. Construir as visualizações (Lens)

Vamos criar 5 painéis, um de cada vez, e salvar cada um com um nome padronizado (`nginx-lab: ...`) para facilitar ao montar o dashboard depois.

### 5.1 — Requisições por status (série temporal empilhada)

1. Menu ☰ → **Visualize Library** → **Create visualization** → **Lens**;
2. No seletor de dados (topo), escolha o data view **logs-nginx.access-***;
3. Arraste o campo `@timestamp` para a área central — o Lens cria automaticamente um gráfico de barras por tempo;
4. No painel direito, em **Break down by**, adicione `http.response.status_code` (tipo **Top values**, tamanho 6);
5. Tipo de gráfico (canto superior direito da área de edição): **Bar vertical stacked**;
6. Renomeie o eixo Y clicando nele: "Requisições";
7. **Save** → nome: `nginx-lab: requisições por status`.

### 5.2 — Taxa de erro (%)

1. **Create visualization** → **Lens**, data view **logs-nginx.access-***;
2. Clique em **Add** no painel de campos (ou arraste `@timestamp` novamente para o eixo X);
3. No eixo de valores, clique em **Add or drag-and-drop a field** → **Formula**;
4. Cole a fórmula:

```
count(kql='http.response.status_code >= 400') / count() * 100
```

5. Nomeie a métrica: "Taxa de erro (%)";
6. Tipo de gráfico: **Line**;
7. **Save** → nome: `nginx-lab: taxa de erro (%)`.

### 5.3 — Top rotas com erro (tabela)

1. **Create visualization** → **Lens**, data view **logs-nginx.access-***;
2. Tipo de gráfico: **Table** (menu no canto superior direito);
3. **Rows**: arraste `url.path` → **Top values**, tamanho 10, ordenado por contagem;
4. **Metric**: `Count of records`;
5. Adicione um filtro do próprio painel: clique em **Add filter** (parte inferior) → `http.response.status_code >= 400`;
6. **Save** → nome: `nginx-lab: top rotas com erro`.

### 5.4 — Conexões ativas do nginx (stub_status via Metricbeat)

1. **Create visualization** → **Lens**, troque o data view para **metricbeat-***;
2. Eixo X: `@timestamp`;
3. Eixo Y: campo `nginx.stubstatus.active` (métrica **Average**);
4. **Break down by**: `kubernetes.pod.name` (Top values, tamanho 5) — mostra as réplicas do `nginx-web` separadamente;
5. Tipo de gráfico: **Line**;
6. **Save** → nome: `nginx-lab: conexões ativas (stub_status)`.

> Se o campo `nginx.stubstatus.active` não aparecer na lista, confira a seção **Troubleshooting** — normalmente é falta das *hints* de autodiscover no `nginx-web` ou o Metricbeat ainda não coletou nenhum ciclo.

### 5.5 — Saúde do nó (CPU e memória)

1. **Create visualization** → **Lens**, data view **metricbeat-***;
2. Eixo X: `@timestamp`;
3. Eixo Y (métrica 1): `system.cpu.total.norm.pct`, **Average**;
4. Clique em **Add layer** → mesmo eixo X, métrica 2: `system.memory.actual.used.pct`, **Average**;
5. Tipo de gráfico: **Line**;
6. Formate o eixo Y como percentual: clique no eixo → **Value format** → **Percent**;
7. **Save** → nome: `nginx-lab: saúde do nó (CPU/memória)`.

---

## 6. Montar o Dashboard

1. Menu ☰ → **Dashboards** → **Create dashboard**;
2. **Add from library** → adicione, um por vez, os 5 painéis salvos na seção 5 (busque por `nginx-lab:`);
3. Reorganize arrastando pelos cantos/bordas dos painéis. Sugestão de layout:
   - Linha 1 (largura toda): `requisições por status`
   - Linha 2 (metade cada): `taxa de erro (%)` | `top rotas com erro`
   - Linha 3 (metade cada): `conexões ativas (stub_status)` | `saúde do nó`
4. No canto superior direito, ajuste o intervalo de tempo para **Last 30 minutes** e o auto-refresh (ícone de relógio ao lado) para **10 seconds** — assim o dashboard atualiza sozinho durante os testes de caos;
5. **Save** → nome: `Nginx Lab — Observabilidade`, marque **Store time with dashboard** para o intervalo/refresh serem lembrados;
6. Confirme.

### 6.1 — Adicionar um controle de filtro (opcional, recomendado)

Permite trocar entre `nginx-web` e `nginx-chaos` sem editar KQL manualmente:

1. No dashboard, **Edit** → **Add panel** → **Controls** → **Add control**;
2. Campo: `kubernetes.labels.app`, tipo **Options list**;
3. **Save and close** → **Save** o dashboard novamente.

---

## 7. Exercício guiado: acompanhando um cenário de caos ao vivo

1. Deixe o dashboard aberto em uma aba, com auto-refresh em 10s;
2. Em outra aba, abra o painel `http://<IP-do-host>:30090`;
3. Rode o cenário **Erros 500** com 20 rps por 5 minutos;
4. Observe no dashboard:
   - `requisições por status` — barras vermelhas (5xx) crescendo;
   - `taxa de erro (%)` — subindo acima de ~70% (o mix do cenário é majoritariamente erro);
   - `top rotas com erro` — `/erro/500` no topo;
   - `conexões ativas` — pico correlacionado com o início do cenário;
5. Pare o cenário no painel de caos (**■ Parar tudo**) e observe as métricas normalizarem nos minutos seguintes.

Repita com os cenários **Latência alta** (observe `conexões ativas` subir sem crescimento proporcional de erro) e **Caos total** (mistura de sintomas).

---

## 8. Criar um alerta a partir do dashboard

1. No dashboard, clique nos `⋮` (menu de opções, canto superior direito) → **Alerts** → **Create alert rule**
   — ou vá direto em **Observability → Alerts → Manage Rules → Create rule**;
2. Tipo de regra: **Custom threshold**;
3. Índice: `logs-nginx.access-*`;
4. **WHEN**: `Count()` **OF** filtro `http.response.status_code >= 500` **IS ABOVE** um valor (ex.: `50`) **FOR THE LAST** `2 minutes`;
5. Defina uma ação (ex.: **Server log**, suficiente para o lab) e salve;
6. Valide disparando o cenário **Erros 500** (seção 7) e acompanhando em **Observability → Alerts** o status mudar para **Active**.

---

## 9. Exportando o dashboard (versionar no repositório)

Para levar o dashboard para o Git junto com o restante da automação:

1. **Stack Management → Saved Objects**;
2. Busque `Nginx Lab — Observabilidade`;
3. Marque o checkbox do dashboard → **Export** → **Include related objects** (isso arrasta os 5 painéis, o data view e o controle juntos);
4. Salve o `.ndjson` gerado em `docs/kibana-dashboard-export.ndjson` no repositório;
5. Documente no `README.md` como reimportar:

```bash
# Reimportar em outro ambiente:
# Stack Management → Saved Objects → Import → selecione o .ndjson
```

---

## 10. Rotina rápida do dia a dia

| Ação | Onde |
|---|---|
| Ver o estado geral do lab | Dashboard `Nginx Lab — Observabilidade` |
| Investigar uma anomalia específica | **Discover**, data view `logs-nginx.access-*`, filtro KQL |
| Rodar um novo teste de carga/falha | Painel `nginx-chaos` (`:30090`) |
| Conferir se os componentes do stack estão saudáveis | `kubectl -n elastic get elasticsearch,kibana,logstash,beat` |
| Ver quem está disparando alertas | **Observability → Alerts** |

---

## Troubleshooting deste manual

**Data view `logs-nginx.access-*` sem campos / sem documentos**
Confirme que há dados no índice antes de criar o data view:
```bash
PASS=$(kubectl -n elastic get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n elastic exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:${PASS}" "https://localhost:9200/logs-nginx.access-*/_count"
```
Se `count: 0`, revise `docs/troubleshooting.md` (seção Filebeat/Logstash) — provavelmente o Filebeat não está entregando ao Logstash, ou o índice ainda não foi criado por falta de tráfego.

**Campo `nginx.stubstatus.active` não aparece no Lens**
Confirme que as *hints* de autodiscover estão nas annotations do pod `nginx-web`:
```bash
kubectl -n apps get pod -l app=nginx-web -o jsonpath='{.items[0].metadata.annotations}'
```
Deve conter `co.elastic.metrics/module: nginx`. Se sumiu, reaplique a fase `apps`:
```bash
ansible-playbook site.yml -K --tags apps
```

**Dashboard não atualiza sozinho**
Confirme que o auto-refresh está ativo (ícone de relógio, canto superior direito) e não em "Off".

**Alerta não dispara**
Verifique se a regra está **Enabled** em **Observability → Alerts → Manage Rules**, e se o intervalo de checagem da regra (**Advanced options → Check every**) é compatível com a janela usada na condição (ex.: checar a cada 1 min para uma janela de 2 min).
