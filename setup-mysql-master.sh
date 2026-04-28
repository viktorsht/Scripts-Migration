#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }

DB_NAME=""
DB_PASSWORD=""
CONTAINER_NAME=""
REPLICA_PASS=""
REPLICA_USER="replicador"
SERVER_ID=1

usage() {
  echo ""
  echo "Uso: $0 --db NOME --password SENHA --container NOME_CONTAINER --replica-pass SENHA"
  echo ""
  echo "  --db              Nome do banco de dados"
  echo "  --password        Senha root do MySQL"
  echo "  --container       Nome do container Docker"
  echo "  --replica-pass    Senha do usuário de replicação"
  echo "  --replica-user    Usuário de replicação (padrão: replicador)"
  echo "  --server-id       server-id do master (padrão: 1)"
  echo ""
  echo "Exemplo:"
  echo "  $0 --db minha_base --password senha123 --container banco-teste-mysql --replica-pass replica123"
  echo ""
  exit 1
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)            DB_NAME="$2";        shift 2 ;;
    --password)      DB_PASSWORD="$2";    shift 2 ;;
    --container)     CONTAINER_NAME="$2"; shift 2 ;;
    --replica-pass)  REPLICA_PASS="$2";   shift 2 ;;
    --replica-user)  REPLICA_USER="$2";   shift 2 ;;
    --server-id)     SERVER_ID="$2";      shift 2 ;;
    -h|--help) usage ;;
    *) error "Argumento desconhecido: $1" ;;
  esac
done

[[ -z "$DB_NAME" ]]        && error "--db obrigatório"
[[ -z "$DB_PASSWORD" ]]    && error "--password obrigatório"
[[ -z "$CONTAINER_NAME" ]] && error "--container obrigatório"
[[ -z "$REPLICA_PASS" ]]   && error "--replica-pass obrigatório"

command -v docker &>/dev/null || error "Docker não encontrado."

# ── SQL helpers ────────────────────────────────────────────────────────────────
sql() {
  docker exec "$CONTAINER_NAME" mysql \
    -uroot -p"${DB_PASSWORD}" --connect-timeout=10 -e "$1" 2>/dev/null
}
sql_s() {
  docker exec "$CONTAINER_NAME" mysql \
    -uroot -p"${DB_PASSWORD}" --connect-timeout=10 --silent -e "$1" 2>/dev/null
}

echo ""
info "============================================================"
info "  Banco:     $DB_NAME"
info "  Container: $CONTAINER_NAME"
info "============================================================"
echo ""

# ── 1. Container existe e está rodando? ───────────────────────────────────────
info "Verificando container '$CONTAINER_NAME'..."
docker inspect "$CONTAINER_NAME" &>/dev/null || error "Container '$CONTAINER_NAME' não encontrado."
STATUS=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Status}}')
[[ "$STATUS" != "running" ]] && error "Container está '$STATUS'. Precisa estar 'running'."
success "Container rodando."

# ── 2. Conectividade ──────────────────────────────────────────────────────────
info "Testando conexão MySQL..."
sql "SELECT 1;" &>/dev/null || error "Falha na conexão. Verifique a senha."
success "Conexão OK."

# ── 3. Banco existe? ──────────────────────────────────────────────────────────
info "Verificando banco '$DB_NAME'..."
EXISTS=$(sql_s "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")
if [[ -z "$EXISTS" ]]; then
  warn "Banco '$DB_NAME' não encontrado."
  read -rp "  Deseja criá-lo agora? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || error "Banco não existe. Crie-o antes de continuar."
  sql "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  success "Banco '$DB_NAME' criado."
else
  success "Banco '$DB_NAME' encontrado."
fi

# ── 4. Binary Log ─────────────────────────────────────────────────────────────
info "Verificando Binary Log..."
LOG_BIN=$(sql_s "SHOW VARIABLES LIKE 'log_bin';" | awk '{print $2}')
BINLOG_DB=$(sql_s "SHOW VARIABLES LIKE 'binlog_do_db';" | awk '{print $2}')
BINLOG_FMT=$(sql_s "SHOW VARIABLES LIKE 'binlog_format';" | awk '{print $2}')
CURRENT_SERVER_ID=$(sql_s "SHOW VARIABLES LIKE 'server_id';" | awk '{print $2}')

NEEDS_RESTART=false

if [[ "$LOG_BIN" != "ON" ]] || [[ -n "$BINLOG_DB" ]] || [[ "$BINLOG_FMT" != "ROW" ]]; then
  [[ "$LOG_BIN" != "ON" ]]  && warn "Binary Log desativado."
  [[ -n "$BINLOG_DB" ]]     && warn "binlog_do_db='$BINLOG_DB' detectado — causa perda de eventos. Será removido."
  [[ "$BINLOG_FMT" != "ROW" ]] && warn "binlog_format=$BINLOG_FMT — será corrigido para ROW."

  info "Escrevendo configuração correta no container..."
  docker exec "$CONTAINER_NAME" bash -c "cat > /etc/mysql/conf.d/replication.cnf <<EOF
[mysqld]
server-id        = ${SERVER_ID}
log_bin          = mysql-bin
binlog_format    = ROW
expire_logs_days = 7
EOF"
  NEEDS_RESTART=true
else
  success "Binary Log ativo, ROW format, sem binlog_do_db."
fi

if [[ "$CURRENT_SERVER_ID" != "$SERVER_ID" ]]; then
  warn "server-id atual ($CURRENT_SERVER_ID) diferente do esperado ($SERVER_ID). Será corrigido."
  NEEDS_RESTART=true
fi

if $NEEDS_RESTART; then
  info "Reiniciando container para aplicar configurações..."
  docker restart "$CONTAINER_NAME"
  info "Aguardando MySQL reiniciar..."
  for i in $(seq 1 30); do
    docker exec "$CONTAINER_NAME" mysqladmin ping \
      -uroot -p"${DB_PASSWORD}" --silent 2>/dev/null && break
    [[ $i -eq 30 ]] && error "MySQL não voltou após restart."
    sleep 2
  done
  success "MySQL reiniciado."

  # Revalida
  LOG_BIN=$(sql_s "SHOW VARIABLES LIKE 'log_bin';" | awk '{print $2}')
  [[ "$LOG_BIN" != "ON" ]] && error "Binary Log ainda inativo após restart. Verifique o my.cnf."
  success "Binary Log confirmado ativo."
fi

# ── 5. Usuário de replicação ──────────────────────────────────────────────────
info "Configurando usuário de replicação '$REPLICA_USER'..."
EXISTS_USER=$(sql_s "SELECT User FROM mysql.user WHERE User='${REPLICA_USER}' AND Host='%';")
if [[ -n "$EXISTS_USER" ]]; then
  warn "Usuário já existe — atualizando senha."
  sql "ALTER USER '${REPLICA_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPLICA_PASS}';"
else
  sql "CREATE USER '${REPLICA_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPLICA_PASS}';"
fi
sql "GRANT REPLICATION SLAVE ON *.* TO '${REPLICA_USER}'@'%';"
sql "FLUSH PRIVILEGES;"
success "Usuário '$REPLICA_USER' pronto."

# ── 6. Posição do binlog ──────────────────────────────────────────────────────
info "Capturando posição do binlog..."
MASTER_STATUS=$(sql_s "SHOW MASTER STATUS;")
BINLOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
BINLOG_POS=$(echo  "$MASTER_STATUS" | awk '{print $2}')
[[ -z "$BINLOG_FILE" ]] && error "Não foi possível obter posição do binlog."
success "Binlog: $BINLOG_FILE @ posição $BINLOG_POS"

# ── 7. IP da máquina ──────────────────────────────────────────────────────────
MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$MY_IP" ]] && MY_IP="<IP desta máquina>"

# ── 8. Salva resumo ───────────────────────────────────────────────────────────
SUMMARY="$HOME/mysql-master-${DB_NAME}-info.txt"
cat > "$SUMMARY" <<EOF
=== Master MySQL — ${DB_NAME} — $(date) ===

MASTER
  IP:               ${MY_IP}
  Porta:            3306
  Container:        ${CONTAINER_NAME}
  Banco:            ${DB_NAME}
  server-id:        ${SERVER_ID}
  Binlog file:      ${BINLOG_FILE}
  Binlog posição:   ${BINLOG_POS}

CREDENCIAIS DE REPLICAÇÃO
  Usuário:          ${REPLICA_USER}
  Senha:            ${REPLICA_PASS}

COMANDO PARA RODAR NA VM DA REPLICA
  ./setup-mysql-replica.sh \
    --db ${DB_NAME} \
    --password ${DB_PASSWORD} \
    --master-ip ${MY_IP} \
    --master-port 3306 \
    --replica-port 3306 \
    --replica-user ${REPLICA_USER} \
    --replica-pass ${REPLICA_PASS}

CHANGE MASTER TO (manual)
  STOP SLAVE;
  RESET SLAVE ALL;
  CHANGE MASTER TO
    MASTER_HOST     = '${MY_IP}',
    MASTER_PORT     = 3306,
    MASTER_USER     = '${REPLICA_USER}',
    MASTER_PASSWORD = '${REPLICA_PASS}',
    MASTER_LOG_FILE = '${BINLOG_FILE}',
    MASTER_LOG_POS  = ${BINLOG_POS};
  START SLAVE;

VERIFICAR MASTER
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'SHOW MASTER STATUS\G'
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'SHOW PROCESSLIST\G'
EOF

# ── Saída final ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Master '${DB_NAME}' pronto!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
cat "$SUMMARY"
echo ""
success "Arquivo salvo em: $SUMMARY"
echo ""