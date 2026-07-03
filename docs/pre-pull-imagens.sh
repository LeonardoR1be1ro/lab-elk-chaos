#!/usr/bin/env bash
# ============================================================
# Pré-pull de todas as imagens usadas no lab, via containerd
# do k3s. Rode ANTES do "ansible-playbook site.yml" para evitar
# timeouts de rollout enquanto o cluster baixa imagens grandes.
#
# Uso:
#   chmod +x docs/pre-pull-imagens.sh
#   sudo ./docs/pre-pull-imagens.sh
#
# As versões abaixo devem bater com group_vars/all.yml
# (stack_version / eck_version). Se você alterar lá, altere aqui.
# ============================================================
set -euo pipefail

STACK_VERSION="9.4.2"
ECK_VERSION="3.4.0"
NGINX_VERSION="1.27"

IMAGES=(
  "docker.elastic.co/eck/eck-operator:${ECK_VERSION}"
  "docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}"
  "docker.elastic.co/kibana/kibana:${STACK_VERSION}"
  "docker.elastic.co/logstash/logstash:${STACK_VERSION}"
  "docker.elastic.co/beats/filebeat:${STACK_VERSION}"
  "docker.elastic.co/beats/metricbeat:${STACK_VERSION}"
  "docker.io/library/nginx:${NGINX_VERSION}"
)

echo "==> Pré-pull de ${#IMAGES[@]} imagens via containerd do k3s"
echo

for img in "${IMAGES[@]}"; do
  echo "--- ${img}"
  time k3s ctr images pull "${img}"
  echo
done

echo "==> Imagens presentes no containerd do k3s:"
k3s ctr images ls | grep -E "eck-operator|elasticsearch|kibana|logstash|beats|nginx"
