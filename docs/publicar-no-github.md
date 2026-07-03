# Publicando o projeto no GitHub — passo a passo

## 0. Antes de começar

- Conta criada em <https://github.com>;
- `git` instalado (`sudo dnf install -y git`);
- Identidade configurada:

```bash
git config --global user.name "Seu Nome"
git config --global user.email "seu-email@exemplo.com"
git config --global init.defaultBranch main
```

## 1. Revisão de segurança (obrigatória)

Antes do primeiro commit, garanta que **nenhum segredo** será versionado:

```bash
# Nada de kubeconfig, senhas ou certificados no diretório
grep -rIl "BEGIN.*PRIVATE KEY" . 2>/dev/null
ls k3s.yaml *.kubeconfig 2>/dev/null
```

O `.gitignore` do projeto já bloqueia `k3s.yaml`, `*.kubeconfig`, `*.pem`, `*.key`, `*.crt` e `.env`. A senha do usuário `elastic` vive apenas em um Secret do cluster — nunca a copie para arquivos do repositório.

## 2. Inicializar o repositório local

```bash
cd elastic-k8s-chaos-lab
git init -b main
git add .
git status                      # revise a lista de arquivos
git commit -m "feat: lab Elastic Stack (ECK) + chaos engineering em k3s no Fedora 44"
```

## 3. Criar o repositório no GitHub

### Opção A — pela interface web

1. Acesse <https://github.com/new>;
2. **Repository name**: `elastic-k8s-chaos-lab`;
3. Descrição sugerida: *"Lab de observabilidade: Elastic Stack via ECK em k3s (Fedora 44), com painel de chaos engineering — provisionado com Ansible"*;
4. Visibilidade: **Public** (portfólio) ou **Private**;
5. **Não** marque a criação de README, .gitignore ou licença (já existem no projeto);
6. Clique em **Create repository**.

### Opção B — pelo GitHub CLI

```bash
sudo dnf install -y gh
gh auth login                   # siga o fluxo no navegador
gh repo create elastic-k8s-chaos-lab --public \
  --source=. --remote=origin --push \
  --description "Lab de observabilidade: Elastic Stack (ECK) em k3s + chaos engineering, com Ansible"
```

Se usou a Opção B, o push já foi feito — pule para o passo 6.

## 4. Conectar o remoto

Via **SSH** (recomendado):

```bash
# Gere a chave, se ainda não tiver
ssh-keygen -t ed25519 -C "seu-email@exemplo.com"
cat ~/.ssh/id_ed25519.pub
# Cadastre em GitHub → Settings → SSH and GPG keys → New SSH key
ssh -T git@github.com          # deve responder com seu usuário

git remote add origin git@github.com:<seu-usuario>/elastic-k8s-chaos-lab.git
```

Via **HTTPS** (requer Personal Access Token como senha):

```bash
git remote add origin https://github.com/<seu-usuario>/elastic-k8s-chaos-lab.git
```

> Token: GitHub → Settings → Developer settings → Personal access tokens → *Fine-grained token* com permissão de escrita em Contents no repositório.

## 5. Enviar o código

```bash
git push -u origin main
```

## 6. Pós-publicação (recomendado)

- **Topics** (About → ⚙): `ansible`, `kubernetes`, `k3s`, `elastic-stack`, `eck`, `observability`, `chaos-engineering`, `sre`, `fedora`;
- **Releases**: `git tag -a v1.0.0 -m "Primeira versão do lab" && git push origin v1.0.0`;
- Confira se o README renderizou corretamente (diagrama ASCII e tabelas).

## 7. Fluxo de atualizações

```bash
git checkout -b feat/nova-melhoria
# ... edite ...
git add -p
git commit -m "feat: descreve a melhoria"
git push -u origin feat/nova-melhoria
# Abra o Pull Request no GitHub e faça o merge em main
```

Padrão de mensagens sugerido (Conventional Commits): `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.
