.PHONY: check setup deploy status password destroy destroy-full

check:            ## Valida Fedora 45 e as ferramentas necessarias
	@set -eu; \
	if [ ! -r /etc/os-release ]; then echo "ERRO: este laboratorio deve ser executado no Fedora 45."; exit 1; fi; \
	. /etc/os-release; \
	if [ "$${ID:-}" != "fedora" ] || [ "$${VERSION_ID:-0}" -lt 45 ]; then \
	  echo "ERRO: Fedora 45 ou superior esperado (detectado: $${PRETTY_NAME:-desconhecido})."; exit 1; \
	fi; \
	for cmd in ansible-playbook ansible-galaxy kubectl; do \
	  command -v "$$cmd" >/dev/null 2>&1 || { echo "ERRO: comando '$$cmd' nao encontrado."; exit 1; }; \
	done; \
	echo "OK: Fedora $${VERSION_ID} e ferramentas essenciais detectados."

setup:            ## Instala as collections Ansible necessárias
	sudo dnf install -y ansible-core git python3-kubernetes
	ansible-galaxy collection install -r requirements.yml

deploy:           ## Executa o provisionamento completo
	ansible-playbook site.yml -K

status:           ## Mostra o estado dos recursos do laboratório
	kubectl get elasticsearch,kibana,logstash,beat -n elastic ; \
	kubectl get pods -n elastic ; \
	kubectl get pods,svc -n apps

password:         ## Exibe a senha do usuário elastic
	kubectl -n elastic get secret elasticsearch-es-elastic-user \
	  -o jsonpath='{.data.elastic}' | base64 -d ; echo

destroy:          ## Remove apenas os workloads (mantém o k3s)
	ansible-playbook destroy.yml -K

destroy-full:     ## Remove tudo, inclusive o k3s
	ansible-playbook destroy.yml -K -e destroy_scope=full
