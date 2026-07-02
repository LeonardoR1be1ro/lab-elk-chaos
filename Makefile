.PHONY: setup deploy status password destroy destroy-full

setup:            ## Instala as collections Ansible necessárias
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
