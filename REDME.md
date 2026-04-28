# 🚀 Setup de Replicação MySQL com Docker

Este guia descreve como subir um MySQL em Docker e configurar **replicação Master → Replica** entre duas VMs.

---

## 📦 1. Subir o MySQL (Docker)

Execute o script para criar o container MySQL:

```bash
./run-mysql.sh banco-teste-mysql senha123 minha_base 3306
```

### 🔹 Parâmetros:

* `banco-teste-mysql` → Nome do container
* `senha123` → Senha do usuário root
* `minha_base` → Nome do banco inicial
* `3306` → Porta exposta no host

---

## ⚙️ 2. Configurar o Master (VM1)

Na máquina de origem (Master), execute:

```bash
./setup-mysql-master.sh \
  --db minha_base \
  --password senha123 \
  --container banco-teste-mysql \
  --replica-pass replica123
```

### 🔹 O que este passo faz:

* Configura o MySQL para permitir replicação
* Cria o usuário de réplica
* Ativa o binlog (necessário para replicação)

---

## 🧬 3. Configurar a Replica (VM2)

Na máquina de destino (Replica), execute:

```bash
./setup-mysql-replica.sh \
  --db minha_base \
  --password senha123 \
  --master-ip 192.168.18.157 \
  --master-port 3306 \
  --replica-port 3306 \
  --replica-pass replica123
```

### 🔹 Parâmetros importantes:

* `master-ip` → IP da VM1 (Master)
* `master-port` → Porta do MySQL no Master
* `replica-port` → Porta local da Replica
* `replica-pass` → Senha do usuário de replicação

---

## 🔥 Pré-requisitos (IMPORTANTE)

### 🔓 Liberar a porta 3306 na VM1 (Master)

```bash
sudo ufw allow 3306/tcp
sudo ufw enable
```

---

## ✅ Verificações

### 🔹 Ver se o container está rodando

```bash
docker ps
```

Saída esperada:

```
0.0.0.0:3306->3306/tcp
```

---

### 🔹 Testar conexão a partir da VM2

```bash
nc -zv 192.168.18.157 3306
```

Saída esperada:

```
succeeded!
```

---

## ⚠️ Problemas comuns

### ❌ Connection refused

* Container não está rodando
* Porta não foi exposta (`-p 3306:3306`)
* IP da VM incorreto

---

### ❌ Timeout

* Firewall bloqueando porta 3306
* VM não está em modo Bridge (VirtualBox)

---

### ❌ Replica não sincroniza

* Usuário de replicação incorreto
* Binlog não ativado no Master

---

## 🧠 Dicas

* Prefira usar **Bridge Adapter** no VirtualBox
* Aguarde alguns segundos após subir o container antes de configurar replicação
* Use portas diferentes se houver conflito (ex: `3307:3306`)

---

## 🎯 Resultado esperado

Após a configuração:

* Escritas feitas na VM1 (Master)
* Serão automaticamente replicadas na VM2 (Replica)
