# Troubleshooting

Organizado por camada, na ordem em que o `site.yml` provisiona: Ansible/host → k3s → ECK/operador → Elasticsearch → Kibana → Logstash → Beats → nginx-web/nginx-chaos → geral.

- [1. Ansible e host](#1-ansible-e-host)
- [2. k3s](#2-k3s)
- [3. Operador ECK](#3-operador-eck)
- [4. Elasticsearch](#4-elasticsearch)
- [5. Kibana](#5-kibana)
- [6. Logstash](#6-logstash)
- [7. Filebeat e Metricbeat](#7-filebeat-e-metricbeat)
- [8. nginx-web e nginx-chaos](#8-nginx-web-e-nginx-chaos)
- [9. Geral](#9-geral)

---

## 1. Ansible e host

### `error loading plugin 'community.general.yaml'` / `no module name 'ansible_collections.community'`

Sintoma: erro logo ao iniciar qualquer `ansible-playbook`.

Causa: o `ansible.cfg` referenciava `stdout_callback = yaml`, um callback que hoje vive em `community.general` — collection não instalada por padrão.

Solução (já aplicada no projeto): usar o callback nativo do ansible-core.

```ini
[defaults]
stdout_callback = ansible.builtin.default
callback_result_format = yaml
```

### `community.general.yaml callback plugin has been removed`

Mesma causa acima, mas em versões mais recentes da collection o callback foi **removido de vez** (não só depreciado) — instalar `community.general` não resolve mais. Use a mesma solução: `ansible.builtin.default` + `callback_result_format = yaml`.

### `[DEPRECATION WARNING]: Direct access to the 'environment' attribute is deprecated`

Aviso cosmético de uma dependência interna da collection `kubernetes.core`/`ansible-core`, sem impacto funcional até a versão 2.23 do ansible-core. Ignore, ou silencie:

```bash
sed -i '/\[defaults\]/a deprecation_warnings = False' ansible.cfg
```

### `Timed out waiting for become success or become password prompt`

Sintoma: o playbook roda bem no início e falha no meio de uma task com espera longa (ex.: aguardar o Elasticsearch ficar saudável).

Causa: `become: true` aplicado ao play inteiro. O cache de credenciais do `sudo` (timestamp) expira por padrão em 5 minutos; se uma task com `retries`/`delay` ultrapassa esse tempo, o Ansible tenta reautenticar o `become` no meio da execução, mas não há terminal interativo esperando — trava.

Solução (já aplicada no `site.yml`/`destroy.yml`): escopar `become: true` **só** nos roles/tasks que realmente precisam de root (`prereqs`, `k3s`, desinstalação do k3s). Tudo que só chama `kubectl` roda sem `become`, já que o kubeconfig do k3s é legível pelo usuário (`--write-kubeconfig-mode 644`).

### `ModuleNotFoundError: No module named 'kubernetes'` ao rodar tasks `kubernetes.core.k8s`

Causa: o interpretador Python que o Ansible está usando no controller (`interpreter_python = auto_silent`) não é o mesmo onde o pacote `python3-kubernetes`/`kubernetes` (pip) foi instalado — comum se a lib foi instalada via `pip install --user` num Python diferente do usado pelo `dnf`.

Diagnóstico:

```bash
ansible -m setup localhost -a "filter=ansible_python_interpreter" 2>/dev/null
which python3
python3 -c "import kubernetes; print(kubernetes.__file__)"
```

Solução: garanta que a fase `prereqs` rodou (instala `python3-kubernetes` via `dnf`, no Python de sistema) e que não há um Python de outra origem (`pyenv`, venv ativo) na frente no `PATH` ao rodar o Ansible. Se necessário, force o interpretador:

```ini
# ansible.cfg
[defaults]
interpreter_python = /usr/bin/python3
```

---

## 2. k3s

### Instalação trava ou não conclui

```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 100 --no-pager
```

Causas comuns: porta 6443 já em uso, firewall bloqueando o script de instalação, ou falta de conectividade com `get.k3s.io`/`github.com` (release binária).

### Pods do `kube-system` presos em `Pending`/`ContainerCreating` após reboot

Sintoma: `vm.max_map_count` volta ao padrão do kernel (65530) após reiniciar a máquina, porque o `sysctl` aplicado pela fase `prereqs` não persistiu, ou o arquivo `/etc/sysctl.d/99-elasticsearch.conf` foi removido.

```bash
sysctl vm.max_map_count      # esperado: 262144
cat /etc/sysctl.d/99-elasticsearch.conf
```

Solução: rode a fase `prereqs` de novo após qualquer reboot, antes de reativar o restante:

```bash
ansible-playbook site.yml -K --tags prereqs
```

---

## 3. Operador ECK

### Pod `elastic-operator-0` preso em `Pulling` por muito tempo

```bash
kubectl -n elastic-system describe pod elastic-operator-0 | tail -20
```

Imagem grande (~250-300MB) baixando em rede lenta. Pré-baixe as imagens antes do deploy com `docs/pre-pull-imagens.sh` (usa `k3s ctr images pull`, o containerd correto — **não** `docker pull`, que vai para um daemon diferente do usado pelo k3s).

### `failed calling webhook "elastic-...-validation..." ... connection refused` ao aplicar Elasticsearch/Kibana/Logstash logo após instalar o operador

Causa: **race condition real.** O pod do operador pode reportar `Ready` antes do webhook de admissão (mesmo processo, mas com o certificado TLS gerado de forma assíncrona no boot) estar de fato aceitando conexões no Service `elastic-webhook-server` (namespace `elastic-system`).

Solução (já aplicada no projeto): o role `eck_operator` agora aguarda os *endpoints* desse Service terem ao menos um IP antes de prosseguir:

```bash
kubectl -n elastic-system get endpoints elastic-webhook-server
```

Se você aplicar os CRs manualmente fora do Ansible logo após instalar o operador, espere esse comando retornar um IP antes de continuar.

### CRDs não aplicadas / `no matches for kind "Elasticsearch" in version "elasticsearch.k8s.elastic.co/v1"`

O `kubectl apply -f crds.yaml` falhou silenciosamente (rede) ou a versão do ECK mudou o `apiVersion`. Confirme:

```bash
kubectl get crd | grep elastic
```

Reaplique manualmente se necessário:

```bash
kubectl apply -f https://download.elastic.co/downloads/eck/3.4.0/crds.yaml
```

---

## 4. Elasticsearch

### Preso em "Aguardar ficar saudável (green)" indefinidamente

Sintoma: `ansible-playbook` fica em `FAILED - RETRYING` até estourar os 60 retries, mas `kubectl -n elastic get elasticsearch` já mostra `HEALTH: yellow` e `PHASE: Ready`.

Causa: **não é uma falha real.** Num cluster de **1 nó único** (como este lab), com o número padrão de réplicas (`number_of_replicas: 1`), o cluster **nunca atinge `green`** — não existe um segundo nó para alocar a réplica de cada shard primário. `yellow` é o teto de saúde possível e é totalmente saudável nesse cenário.

Solução (já aplicada em `roles/elastic_stack/tasks/main.yml`):

```yaml
until: es_health.stdout in ["yellow", "green"]
```

### `HEALTH: red`

Diferente de `yellow` — indica que um **shard primário** está sem alocação (não é só a réplica). É sempre um problema real.

```bash
PASS=$(kubectl -n elastic get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n elastic exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:${PASS}" "https://localhost:9200/_cluster/allocation/explain?pretty"
```

Causas comuns num single-node: PVC perdido/recriado com dados órfãos, disco cheio (Elasticsearch recusa novos shards abaixo de um limiar de espaço livre), ou o pod foi recriado com um volume diferente do original. Confira espaço em disco:

```bash
df -h
kubectl -n elastic exec elasticsearch-es-default-0 -- df -h /usr/share/elasticsearch/data
```

### Preso em `Pending` ou `unknown`

```bash
kubectl -n elastic describe pod elasticsearch-es-default-0 | tail -30
kubectl -n elastic get events --sort-by=.lastTimestamp | tail -20
```

Causas comuns:

- **Memória insuficiente** — reduza `es_memory` em `group_vars/all.yml` (mínimo prático: `1Gi`) e reaplique com `--tags elastic`;
- **PVC sem bind** — confira `kubectl get pvc -n elastic` e se a StorageClass `local-path` existe (`kubectl get sc`);
- **`vm.max_map_count` baixo** — ver seção [2. k3s](#2-k3s).

### Preso em `PodInitializing` por muito tempo

Init container `elastic-internal-init-filesystem` fazendo `chown -R` num volume grande ou em disco lento.

```bash
kubectl -n elastic logs elasticsearch-es-default-0 -c elastic-internal-init-filesystem --tail=100
kubectl -n elastic get pod elasticsearch-es-default-0 -o jsonpath='{.status.initContainerStatuses[0]}'
```

Se estiver realmente parado (não só lento), confirme se a imagem já foi baixada (`docs/pre-pull-imagens.sh`) e considere limpar um volume "sujo" de uma tentativa anterior:

```bash
kubectl -n elastic delete pod elasticsearch-es-default-0
```

---

## 5. Kibana

### `red` ou reiniciando

```bash
kubectl -n elastic logs deploy/kibana-kb | tail -30
```

Normalmente é o Elasticsearch ainda inicializando — o Kibana estabiliza quando o ES fica `yellow` ou `green`. Verifique também memória disponível no host.

### Preso em "Kibana server is not ready yet" no navegador, mesmo com o pod `Running`

Causa provável: migração de *saved objects* ainda em andamento (mais lenta em hosts com CPU/memória limitada) ou `kibana_memory` insuficiente para o volume de plugins habilitados por padrão no Stack 9.x.

```bash
kubectl -n elastic logs deploy/kibana-kb --tail=100 | grep -iE "migrat|error|out of memory"
```

Se houver indícios de OOM, aumente `kibana_memory` em `group_vars/all.yml` (experimente `1536Mi`) e reaplique com `--tags elastic`. Migração pode legitimamente levar alguns minutos na primeira subida — aguarde antes de intervir.

---

## 6. Logstash

### Erro 403 antigo continua aparecendo mesmo após corrigir o pipeline

Sintoma: você já ajustou o output do Logstash (ex.: trocou `index => "lab-nginx-*"` por `data_stream => "true"`), confirmou via `kubectl get logstash -o json | jq` que o CR está com a config nova, mas os logs continuam mostrando `Retrying failed action ... _index: "lab-nginx-..."` com `403 security_exception`.

Causa: o **hot-reload da pipeline** (que o ECK aciona automaticamente ao detectar mudança no CR) troca a definição da pipeline para novos eventos, mas **não limpa a fila de retry interna** do plugin de output `elasticsearch`. Documentos que já haviam falhado antes da mudança ficam presos num buffer em memória com o metadata antigo e continuam sendo reenviados indefinidamente, mesmo depois do reload.

Solução: reiniciar o pod do Logstash para descartar esse buffer:

```bash
kubectl -n elastic delete pod logstash-ls-0
kubectl -n elastic get pods -l logstash.k8s.elastic.co/name=logstash -w
```

Como é um StatefulSet, o pod é recriado automaticamente já com a config nova e sem a fila zumbi.

### Logstash em retry infinito / Filebeat reporta "Logstash host may be stalled"

Sintoma: nos logs do Filebeat aparece `Logstash batch hasn't reported progress in the last 5m0s`; nos logs do Logstash aparece `Retrying failed action` com `status: 403` e `security_exception: action [indices:admin/auto_create] is unauthorized for user [elastic-logstash-...]`.

Causa: o usuário gerenciado pelo ECK para o Logstash usa a role interna `eck_logstash_user_role`, que **não é customizável** e só concede `auto_create`/`manage` para índices que seguem a convenção de *data stream* da Elastic (`logs-*`, `metrics-*`, `traces-*`, `synthetics-*`). Um índice clássico com nome arbitrário (ex.: `lab-nginx-2026.07.02`) é rejeitado.

Solução (já aplicada neste projeto): usar `data_stream => "true"` no output, com `data_stream_type`, `data_stream_dataset` e `data_stream_namespace` — o pipeline escreve em `logs-nginx.access-default`. Confirme:

```bash
kubectl -n elastic exec sts/logstash-ls -- curl -s http://localhost:9600/_node/stats/pipelines?pretty | grep -A5 '"failures"'
```

Se ainda houver `403` após esse ajuste, confira se o campo `[event][dataset]` não está sendo sobrescrito com um valor fora do padrão em algum filtro customizado — o nome final do data stream é `<data_stream_type>-<data_stream_dataset>-<data_stream_namespace>`.

### Índice `logs-nginx.access-*` cheio de documentos que não são do nginx (ex.: logs do próprio Kibana)

Sintoma: `_count` do data stream mostra um número alto (milhares) de documentos, mas ao abrir um documento de exemplo o `message` é claramente de outro componente (Kibana, Elasticsearch, Logstash, algo do `kube-system`) — e mesmo assim `data_stream.dataset` aparece como `"nginx.access"`. Consultas como `http.response.status_code >= 500` não retornam nada mesmo com tráfego de erro gerado, porque os documentos reais do nginx estão diluídos entre milhares de logs de outros pods.

Causa: bug de design no pipeline do Logstash. O filtro condicional (`if [kubernetes][labels][app] == "nginx-web" or == "nginx-chaos"`) só decidia se o `grok`/`date`/`mutate` rodavam — mas o bloco de **output** não tinha condicional nenhuma, e o Filebeat coleta **todos os pods do cluster** via autodiscover (Kibana, Elasticsearch, o próprio Logstash, `kube-system`, etc.), não só o nginx. Como o output fixa `data_stream_dataset => "nginx.access"` incondicionalmente, **todo evento que chega ao Logstash** — nginx ou não — era gravado nesse data stream.

Solução (já aplicada neste projeto): descartar explicitamente no filtro qualquer evento que não seja do nginx, antes de chegar ao output:

```
filter {
  if [kubernetes][labels][app] == "nginx-web" or [kubernetes][labels][app] == "nginx-chaos" {
    # grok, date, mutate...
  } else {
    drop { }
  }
}
```

Depois de aplicar o fix, **o índice antigo continua "sujo"** com os documentos incorretos já gravados — o `drop` só afeta eventos novos. Para um lab, o mais simples é deletar o data stream e recomeçar do zero:

```bash
PASS=$(kubectl -n elastic get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n elastic exec elasticsearch-es-default-0 -- \
  curl -sk -u "elastic:${PASS}" -X DELETE "https://localhost:9200/_data_stream/logs-nginx.access-default"

# reaplica o pipeline corrigido e reinicia o Logstash pra limpar qualquer fila de retry
ansible-playbook site.yml -K --tags elastic
kubectl -n elastic delete pod logstash-ls-0
```

Depois disso, gere tráfego (`curl` no `nginx-web`/`nginx-chaos`) e confirme que o `_count` volta a crescer só com documentos que de fato têm `http.response.status_code` no `_source`.

### Logs com a tag `nginx_grok_failure`

O formato de log difere do *combined* padrão. Ajuste o pattern no `logstash.yml.j2` e reaplique com `--tags elastic` (o ECK faz o reload do pipeline).

### `Pipeline main` demora a iniciar / JVM lenta no boot

Normal na primeira subida — o log `Pipeline Java execution initialization time` pode levar 10-15s num host modesto. Só investigue se passar de ~2 minutos sem log nenhum:

```bash
kubectl -n elastic logs sts/logstash-ls --tail=50
```

---

## 7. Filebeat e Metricbeat

### `Error: unknown shorthand flag: 's' in -system.hostfs=/hostfs`

Causa: flag de linha de comando com hífen simples (`-system.hostfs`) em vez de duplo (`--system.hostfs`) no `args` do container — o parser Cobra interpreta um único hífen como uma sequência de *shorthand flags*.

Solução (já aplicada): `--system.hostfs=/hostfs` no template `roles/beats/templates/metricbeat.yml.j2`.

### `Error fetching data for metricset system.process ... most likely a "permission denied" error`

Causa: falta `hostPID: true` no pod do Metricbeat. Mesmo montando `/proc` do host via `hostPath` e rodando como `runAsUser: 0`, sem compartilhar o namespace de PID do host o container não consegue ler `/proc/<pid>/` de processos que não pertencem ao seu próprio namespace — só enxerga os diretórios, não o conteúdo.

Solução (já aplicada): `hostPID: true` no `podTemplate.spec` do Metricbeat.

Se o erro persistir mesmo com `hostPID: true`, teste SELinux como fator adicional (próxima seção) — mas trate isso como segunda hipótese, não a primeira.

### SELinux bloqueando os hostPath (`/proc`, `/sys/fs/cgroup`, `/var/log/containers`)

Fedora 44 vem com SELinux `Enforcing` por padrão. Containers com `hostPath` para diretórios sensíveis do host podem esbarrar em *denials*, mesmo com `runAsUser: 0` e (no caso do Metricbeat) `hostPID: true`.

Diagnóstico:

```bash
getenforce
sudo ausearch -m avc -ts recent 2>/dev/null | tail -30
```

Teste temporário (**apenas diagnóstico — não deixe assim em produção**):

```bash
sudo setenforce 0
kubectl -n elastic delete pod -l 'beat.k8s.elastic.co/name in (filebeat,metricbeat)'
# se os pods ficarem saudáveis agora, SELinux era um fator
sudo setenforce 1
```

Se confirmado, o caminho correto é rotular os diretórios montados com um contexto adequado em vez de desabilitar globalmente:

```bash
sudo semanage fcontext -a -t container_file_t "/var/log/containers(/.*)?"
sudo restorecon -Rv /var/log/containers
```

(repita o padrão para `/var/log/pods` e demais hostPaths usados pelos Beats, ajustando o tipo de contexto conforme necessário).

### `Auto discover config check failed ... won't start runner, err: Found container input configuration: Container input is deprecated`

Sintoma: **nenhum log novo chega ao Elasticsearch**, mesmo com o Filebeat `Running` e sem erros óbvios de conexão. O sintoma é inconsistente à primeira vista — pode até haver documentos antigos indexados, criando a falsa impressão de que "às vezes funciona".

Causa: a partir do Filebeat 8.12+/9.x, o input `container` (usado por padrão no `hints.default_config` do autodiscover) foi bloqueado — não é mais um aviso, é um erro que **impede o harvester de iniciar** (`won't start runner`) para qualquer container novo descoberto. Documentos antigos podem ter vindo de harvesters iniciados antes dessa mudança ter efeito (ex.: antes de um restart do Filebeat), mas **nenhum pod recriado depois** (Deployment reiniciado, rollout, `kubectl delete pod`) nunca mais ganha um harvester novo.

Solução (já aplicada em `roles/beats/templates/filebeat.yml.j2`): migrar o `hints.default_config` para o input `filestream` com o parser `container`, o substituto oficial recomendado pela Elastic:

```yaml
hints.default_config:
  type: filestream
  id: "kubernetes-container-logs-${data.kubernetes.container.id}"
  paths:
    - /var/log/containers/*-${data.kubernetes.container.id}.log
  prospector.scanner.symlinks: true
  close.on_state_change.removed: false
  parsers:
    - container: ~
```

Depois de aplicar, confirme que o erro sumiu e que harvesters novos estão abrindo:

```bash
kubectl -n elastic delete pod -l beat.k8s.elastic.co/name=filebeat
kubectl -n elastic logs ds/filebeat-beat-filebeat --tail=100 | grep -iE "won't start runner|Harvester started"
```

Não deve mais aparecer `won't start runner`. Deve aparecer `Harvester started for file: ...` para os pods do `nginx-web`/`nginx-chaos` (e qualquer outro pod do cluster, já que o autodiscover ainda é cluster-wide — o filtro do Logstash é quem decide o que vira `logs-nginx.access-*`, ver seção 6).

### `filestream input ID '...' is duplicated` seguido de `all new inputs failed to start with a non-retriable error`

Sintoma: mesmo depois de corrigir o input `container` → `filestream` (ver entrada anterior), ainda não chega nenhum log novo — inclusive de pods que nunca deram erro antes.

Causa: o **ECK injeta automaticamente annotations de módulo** (`co.elastic.logs/module: kibana`, `elasticsearch`, etc.) nos próprios pods do Elastic Stack, para facilitar autodiscovery. Isso faz o Filebeat gerar **mais de um** fileset por container (ex.: `audit` + `log` para o Kibana) — e se o `id` do filestream configurado em `hints.default_config` for derivado só do `${data.kubernetes.container.id}`, os dois filesets do mesmo container colidem no mesmo ID. O Filebeat rejeita com `is duplicated: input will NOT start`, e — mais grave — **isso derruba o lote inteiro daquele ciclo de reload do autodiscover**, incluindo qualquer pod novo (nginx-web, nginx-chaos) descoberto na mesma leva. Ou seja: um problema de config nos pods do *próprio* Elastic Stack bloqueia silenciosamente a coleta dos pods que você realmente quer monitorar.

### `no such parser accessing config`

Sintoma relacionado ao anterior: `Auto discover config check failed ... won't start runner, err: runner factory could not check config: : no such parser accessing config`.

Causa: `parsers: [{ container: ~ }]` (valor nulo em YAML) colapsa para `parsers: [null]` ao passar pelo campo `config` (tipo JSON arbitrário) do Beat CR do ECK. O Filebeat não sabe interpretar um parser `null` — ele espera um objeto com uma chave conhecida (`container`, `ndjson`, `multiline`, etc.), mesmo que essa chave não precise de sub-opções.

Solução (já aplicada neste projeto, resolvendo as duas causas de uma vez): abandonar `hints`-based autodiscover em favor de um **template com condição explícita**, escopado só aos pods do `nginx-web`/`nginx-chaos`. Isso evita por completo que o Filebeat avalie hints injetados pelo ECK nos outros componentes do stack (elimina a colisão de ID) e usa um parser com campo concreto em vez de `~` (elimina o colapso para `null`):

```yaml
filebeat.autodiscover:
  providers:
    - type: kubernetes
      node: ${NODE_NAME}
      templates:
        - condition:
            or:
              - equals:
                  kubernetes.labels.app: "nginx-web"
              - equals:
                  kubernetes.labels.app: "nginx-chaos"
          config:
            - type: filestream
              id: "nginx-container-logs-${data.kubernetes.container.id}"
              paths:
                - /var/log/containers/*-${data.kubernetes.container.id}.log
              prospector.scanner.symlinks: true
              close.on_state_change.removed: false
              parsers:
                - container:
                    stream: all
```

Efeito colateral positivo: como o Filebeat agora só harvesteia os pods do nginx, o `else { drop {} }` que adicionamos no filtro do Logstash (seção anterior) vira uma segunda camada de proteção, não a única — e os erros de `Error decoding JSON: invalid character '-' after array element` (autodiscover tentando interpretar logs do Kibana como JSON) somem por completo, já que o Filebeat nem avalia mais esses pods.

Depois de aplicar, force o restart e confirme:

```bash
kubectl -n elastic delete pod -l beat.k8s.elastic.co/name=filebeat
kubectl -n elastic logs ds/filebeat-beat-filebeat --tail=100 | grep -iE "duplicated|no such parser|Harvester started"
```

Não deve mais aparecer `duplicated` nem `no such parser`. Deve aparecer `Harvester started` apenas para arquivos de log do `nginx-web`/`nginx-chaos`.

### Filebeat não entrega logs

```bash
kubectl -n elastic logs ds/filebeat-beat-filebeat | grep -iE "error|connect" | tail
```

- `connection refused` para `logstash-ls-beats:5044` → confirme o Service (`kubectl -n elastic get svc logstash-ls-beats`) e os logs do Logstash;
- Sem eventos de pods → confira o RBAC: `kubectl auth can-i list pods --as=system:serviceaccount:elastic:beats`.

### `Error decoding JSON: invalid character '-' after array element`

Ruído inofensivo: o autodiscover por hints tenta interpretar logs de outros pods (ex.: o próprio Kibana) como JSON estruturado quando eles não são. Não afeta a coleta dos logs do `nginx-web`/`nginx-chaos`. Ignore, a menos que o volume desses erros esteja poluindo demais os logs — nesse caso, restrinja o `hints.default_config` do Filebeat por namespace ou label.

### Metricbeat sem métricas do kubelet

```bash
kubectl -n elastic logs ds/metricbeat-beat-metricbeat | grep -i kubelet | tail
```

O módulo `kubernetes` usa `https://${NODE_IP}:10250` com `ssl.verification_mode: none`. Se houver recusa de conexão, valide que a porta 10250 responde no host: `sudo ss -tlnp | grep 10250`.

### Sem dados do módulo nginx (stubstatus)

```bash
kubectl -n apps exec deploy/nginx-chaos -- curl -s http://nginx-web/nginx_status
```

Se o endpoint responder mas o Kibana não mostrar dados, confirme as *annotations* de hints no pod:

```bash
kubectl -n apps get pod -l app=nginx-web -o jsonpath='{.items[0].metadata.annotations}'
```

Deve conter `co.elastic.metrics/module: nginx`. Se ausente, reaplique `--tags apps`.

---

## 8. nginx-web e nginx-chaos

### `ImagePullBackOff` / `429 Too Many Requests` ao baixar `nginx:1.27`

Causa: `nginx:1.27` vem do Docker Hub (diferente das imagens da Elastic, que vêm de `docker.elastic.co`), sujeito ao limite de pulls anônimos do Docker Hub — mais provável em redes compartilhadas (escritório, cloud com IP compartilhado).

```bash
kubectl -n apps describe pod -l app=nginx-web | grep -A3 "Failed to pull image"
```

Soluções:

- Aguarde o reset da janela de rate limit (geralmente 6h para pulls anônimos);
- Pré-baixe a imagem em horário de menor contenção via `docs/pre-pull-imagens.sh`;
- Para uso contínuo, autentique o containerd do k3s num Docker Hub account (mesmo grátis já aumenta o limite):
  ```bash
  sudo k3s ctr images pull --user <usuario>:<token> docker.io/library/nginx:1.27
  ```

### Painel do nginx-chaos com falhas de proxy (502)

O proxy resolve `nginx-web.apps.svc.cluster.local` via CoreDNS (`10.43.0.10`). Se o seu cluster usa outro IP de DNS:

```bash
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'
```

Atualize `cluster_dns` em `group_vars/all.yml` e reaplique com `--tags apps`.

### NodePort inacessível de outra máquina

- Confirme que o firewalld está parado (`systemctl status firewalld`) ou libere as portas 30080/30090/30561;
- Teste local primeiro: `curl http://localhost:30080/ok`;
- De fora, use o IP do host (`ip -4 addr show`), não `localhost`.

---

## 9. Geral

### Extraindo campos aninhados (`config.string`) via `kubectl -o jsonpath`

`kubectl get logstash logstash -o jsonpath='{.spec.pipelines[0]["config.string"]}'` falha com `invalid array index "config.string"` — colchetes no jsonpath do kubectl indicam índice numérico, não nome de campo. Para um campo cujo nome contém ponto, escape com `\.`:

```bash
kubectl -n elastic get logstash logstash -o jsonpath='{.spec.pipelines[0].config\.string}'
```

Ou use `jq` sobre a saída `-o json` (mais tolerante a esse tipo de nome de campo):

```bash
kubectl -n elastic get logstash logstash -o json | jq -r '.spec.pipelines[0]["config.string"]'
```

### Reset completo

```bash
ansible-playbook destroy.yml -K -e destroy_scope=full
ansible-playbook site.yml -K
```
