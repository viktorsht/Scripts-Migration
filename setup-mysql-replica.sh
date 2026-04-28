#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }

DB_NAME=""
DB_PASSWORD=""
MASTER_IP=""
MASTER_PORT="3306"
REPLICA_PORT="3306"
REPLICA_USER="replicador"
REPLICA_PASS=""

usage() {
  echo ""
  echo "Uso: $0 --db NOME --password SENHA --master-ip IP --replica-pass SENHA [opções]"
  echo ""
  echo "  --db              Nome do banco de dados"
  echo "  --password        Senha root do MySQL"
  echo "  --master-ip       IP da VM master"
  echo "  --replica-pass    Senha do usuário de replicação"
  echo "  --master-port     Porta do master          (padrão: 3306)"
  echo "  --replica-port    Porta exposta da replica  (padrão: 3306)"
  echo "  --replica-user    Usuário de replicação     (padrão: replicador)"
  echo ""
  echo "Exemplo:"
  echo "  $0 --db minha_base --password senha123 --master-ip 192.168.1.10 --replica-pass replica123"
  echo ""
  exit 1
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)            DB_NAME="$2";      shift 2 ;;
    --password)      DB_PASSWORD="$2";  shift 2 ;;
    --master-ip)     MASTER_IP="$2";    shift 2 ;;
    --master-port)   MASTER_PORT="$2";  shift 2 ;;
    --replica-port)  REPLICA_PORT="$2"; shift 2 ;;
    --replica-user)  REPLICA_USER="$2"; shift 2 ;;
    --replica-pass)  REPLICA_PASS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) error "Argumento desconhecido: $1" ;;
  esac
done

[[ -z "$DB_NAME" ]]     && error "--db obrigatório"
[[ -z "$DB_PASSWORD" ]] && error "--password obrigatório"
[[ -z "$MASTER_IP" ]]   && error "--master-ip obrigatório"
[[ -z "$REPLICA_PASS" ]] && error "--replica-pass obrigatório"

command -v docker &>/dev/null || error "Docker não encontrado."

CONTAINER="mysql-replica-${DB_NAME}"
WORKDIR="$HOME/mysql-replica-${DB_NAME}"

echo ""
info "============================================================"
info "  Banco:      $DB_NAME"
info "  Master:     $MASTER_IP:$MASTER_PORT"
info "  Container:  $CONTAINER"
info "  Porta:      $REPLICA_PORT"
info "============================================================"
echo ""

# ── 1. Testa acesso ao master ─────────────────────────────────────────────────
info "Testando acesso ao master ${MASTER_IP}:${MASTER_PORT}..."
docker run --rm mysql:8.0 mysql \
  -h"${MASTER_IP}" -P"${MASTER_PORT}" \
  -uroot -p"${DB_PASSWORD}" \
  --connect-timeout=10 --silent \
  -e "SELECT 1;" &>/dev/null \
  || error "Não foi possível conectar ao master. Verifique IP, porta, senha e firewall."
success "Master acessível."

# ── 2. Captura posição atual do binlog no master ───────────────────────────────
info "Capturando posição do binlog no master..."
MASTER_STATUS=$(docker run --rm mysql:8.0 mysql \
  -h"${MASTER_IP}" -P"${MASTER_PORT}" \
  -uroot -p"${DB_PASSWORD}" \
  --connect-timeout=10 --silent \
  -e "SHOW MASTER STATUS;" 2>/dev/null)

BINLOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
BINLOG_POS=$(echo  "$MASTER_STATUS" | awk '{print $2}')

[[ -z "$BINLOG_FILE" ]] && error "Master não retornou posição de binlog. Rode setup-mysql-master.sh no master primeiro."
success "Binlog: $BINLOG_FILE @ posição $BINLOG_POS"

# ── 3. Para e remove container antigo se existir ──────────────────────────────
if docker inspect "$CONTAINER" &>/dev/null; then
  warn "Container '$CONTAINER' já existe — removendo para recriar limpo."
  docker stop "$CONTAINER" 2>/dev/null || true
  docker rm   "$CONTAINER" 2>/dev/null || true
  rm -rf "$WORKDIR/data"
fi

# ── 4. Cria diretório e arquivos de configuração ──────────────────────────────
info "Criando arquivos de configuração em $WORKDIR..."
mkdir -p "$WORKDIR/conf" "$WORKDIR/data"

cat > "$WORKDIR/conf/my.cnf" <<EOF
[mysqld]
server-id           = 2
relay_log           = relay-bin
read_only           = 1
log_bin             = mysql-bin
binlog_format       = ROW
replicate_do_db     = ${DB_NAME}
slave_skip_errors   = 1062,1032
EOF

cat > "$WORKDIR/docker-compose.yml" <<EOF
services:
  mysql-replica:
    image: mysql:8.0
    container_name: ${CONTAINER}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_PASSWORD}"
      MYSQL_DATABASE: "${DB_NAME}"
    ports:
      - "${REPLICA_PORT}:3306"
    volumes:
      - ./data:/var/lib/mysql
      - ./conf/my.cnf:/etc/mysql/conf.d/my.cnf
EOF

success "Arquivos criados."

# ── 5. Sobe container ─────────────────────────────────────────────────────────
info "Subindo container replica..."
cd "$WORKDIR"
docker compose up -d 2>/dev/null || docker-compose up -d

info "Aguardando MySQL inicializar..."
for i in $(seq 1 40); do
  docker exec "$CONTAINER" mysqladmin ping \
    -uroot -p"${DB_PASSWORD}" --silent 2>/dev/null && break
  [[ $i -eq 40 ]] && error "Replica não inicializou após 40 tentativas."
  sleep 2
done
success "Container replica online."

# ── 6. Configura CHANGE MASTER TO ────────────────────────────────────────────
info "Configurando replicação..."
docker exec "$CONTAINER" mysql -uroot -p"${DB_PASSWORD}" -e "
  STOP SLAVE;
  RESET SLAVE ALL;
  CHANGE MASTER TO
    MASTER_HOST     = '${MASTER_IP}',
    MASTER_PORT     = ${MASTER_PORT},
    MASTER_USER     = '${REPLICA_USER}',
    MASTER_PASSWORD = '${REPLICA_PASS}',
    MASTER_LOG_FILE = '${BINLOG_FILE}',
    MASTER_LOG_POS  = ${BINLOG_POS};
  START SLAVE;
" 2>/dev/null
success "CHANGE MASTER TO aplicado."

# ── 7. Verifica status ────────────────────────────────────────────────────────
info "Aguardando threads subirem..."
sleep 5

STATUS=$(docker exec "$CONTAINER" mysql -uroot -p"${DB_PASSWORD}" \
  -e "SHOW SLAVE STATUS\G" 2>/dev/null)

IO=$(echo  "$STATUS" | grep "Slave_IO_Running:"      | awk '{print $2}')
SQL=$(echo "$STATUS" | grep "Slave_SQL_Running:"     | awk '{print $2}')
LAG=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')
ERR_IO=$(echo  "$STATUS" | grep "Last_IO_Error:"     | sed 's/.*Last_IO_Error: //')
ERR_SQL=$(echo "$STATUS" | grep "Last_Error:"        | head -1 | sed 's/.*Last_Error: //')

echo ""
echo -e "  Slave_IO_Running:      ${IO}"
echo -e "  Slave_SQL_Running:     ${SQL}"
echo -e "  Seconds_Behind_Master: ${LAG}"
[[ -n "$ERR_IO"  && "$ERR_IO"  != " " ]] && echo -e "  Last_IO_Error:  $ERR_IO"
[[ -n "$ERR_SQL" && "$ERR_SQL" != " " ]] && echo -e "  Last_SQL_Error: $ERR_SQL"
echo ""

# ── 8. Teste de replicação ao vivo ────────────────────────────────────────────
if [[ "$IO" == "Yes" && "$SQL" == "Yes" ]]; then
  success "Threads de replicação ativas!"

  info "Executando teste de replicação ao vivo..."
  TEST_TABLE="_repl_test_$(date +%s)"

  docker run --rm mysql:8.0 mysql \
    -h"${MASTER_IP}" -P"${MASTER_PORT}" \
    -uroot -p"${DB_PASSWORD}" \
    --connect-timeout=10 \
    -e "USE \`${DB_NAME}\`;
        CREATE TABLE IF NOT EXISTS \`${TEST_TABLE}\` (id INT PRIMARY KEY, msg VARCHAR(50));
        INSERT INTO \`${TEST_TABLE}\` VALUES (1, 'replication_ok');" 2>/dev/null

  sleep 3

  RESULT=$(docker exec "$CONTAINER" mysql -uroot -p"${DB_PASSWORD}" --silent \
    -e "SELECT msg FROM \`${DB_NAME}\`.\`${TEST_TABLE}\` WHERE id=1;" 2>/dev/null || true)

  # Limpa tabela de teste no master
  docker run --rm mysql:8.0 mysql \
    -h"${MASTER_IP}" -P"${MASTER_PORT}" \
    -uroot -p"${DB_PASSWORD}" \
    -e "USE \`${DB_NAME}\`; DROP TABLE IF EXISTS \`${TEST_TABLE}\`;" 2>/dev/null || true

  if echo "$RESULT" | grep -q "replication_ok"; then
    success "Teste passou! Dado replicado com sucesso."
  else
    warn "Dado não chegou na replica após 3s. Verifique o status manualmente."
  fi
else
  warn "Uma ou mais threads não estão ativas. Verifique os erros acima."
fi

# ── 9. Resumo final ───────────────────────────────────────────────────────────
SUMMARY="$WORKDIR/REPLICACAO.txt"
cat > "$SUMMARY" <<EOF
=== Replica MySQL — ${DB_NAME} — $(date) ===

MASTER
  IP / porta:    ${MASTER_IP}:${MASTER_PORT}
  Binlog file:   ${BINLOG_FILE}
  Binlog pos:    ${BINLOG_POS}

REPLICA
  Container:     ${CONTAINER}
  Porta:         ${REPLICA_PORT}
  Diretório:     ${WORKDIR}

CREDENCIAIS
  Root password: ${DB_PASSWORD}
  Repl usuário:  ${REPLICA_USER}
  Repl senha:    ${REPLICA_PASS}

COMANDOS ÚTEIS
  Ver status:
    docker exec ${CONTAINER} mysql -uroot -p${DB_PASSWORD} -e 'SHOW SLAVE STATUS\G'

  Parar replicação:
    docker exec ${CONTAINER} mysql -uroot -p${DB_PASSWORD} -e 'STOP SLAVE;'

  Iniciar replicação:
    docker exec ${CONTAINER} mysql -uroot -p${DB_PASSWORD} -e 'START SLAVE;'

  Conectar:
    docker exec -it ${CONTAINER} mysql -uroot -p${DB_PASSWORD} ${DB_NAME}
EOF

echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Replica '${DB_NAME}' configurada!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
cat "$SUMMARY"
echo ""
success "Arquivo salvo em: $SUMMARY"
echo ""