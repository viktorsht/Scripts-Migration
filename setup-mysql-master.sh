#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }

# ── Defaults ───────────────────────────────────────────────────────────────────
DB_NAME=""
DB_PASSWORD=""
CONTAINER_NAME=""
REPLICA_PASS=""
REPLICA_USER="replicador"
SERVER_ID=1
MASTER_PORT=3306
SKIP_DUMP=false
DUMP_DIR="$HOME"

usage() {
  echo ""
  echo -e "${BOLD}Uso:${NC} $0 [opções]"
  echo ""
  echo "  --db              Nome do banco de dados"
  echo "  --password        Senha root do MySQL"
  echo "  --container       Nome do container Docker"
  echo "  --replica-pass    Senha do usuário de replicação"
  echo "  --replica-user    Usuário de replicação (padrão: replicador)"
  echo "  --server-id       server-id do master (padrão: 1)"
  echo "  --port            Porta do MySQL (padrão: 3306)"
  echo "  --dump-dir        Diretório para salvar o dump (padrão: \$HOME)"
  echo "  --skip-dump       Não gera dump (apenas configura binlog e usuário)"
  echo ""
  echo -e "${BOLD}Exemplos:${NC}"
  echo "  # Configuração completa (recomendado):"
  echo "  $0 --db minha_base --password senha123 --container banco-mysql \\"
  echo "     --replica-pass replica123"
  echo ""
  echo "  # Sem dump (base vazia ou replicação do zero):"
  echo "  $0 --db minha_base --password senha123 --container banco-mysql \\"
  echo "     --replica-pass replica123 --skip-dump"
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
    --port)          MASTER_PORT="$2";    shift 2 ;;
    --dump-dir)      DUMP_DIR="$2";       shift 2 ;;
    --skip-dump)     SKIP_DUMP=true;      shift   ;;
    -h|--help) usage ;;
    *) error "Argumento desconhecido: $1" ;;
  esac
done

# ── Validações ─────────────────────────────────────────────────────────────────
[[ -z "$DB_NAME" ]]        && error "--db obrigatório"
[[ -z "$DB_PASSWORD" ]]    && error "--password obrigatório"
[[ -z "$CONTAINER_NAME" ]] && error "--container obrigatório"
[[ -z "$REPLICA_PASS" ]]   && error "--replica-pass obrigatório"
[[ ! -d "$DUMP_DIR" ]]     && error "Diretório de dump não encontrado: $DUMP_DIR"

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
info "  Server-ID: $SERVER_ID"
info "  Porta:     $MASTER_PORT"
$SKIP_DUMP && info "  Dump:      desativado (--skip-dump)"
info "============================================================"
echo ""

# ── 1. Container existe e está rodando? ───────────────────────────────────────
info "Verificando container '$CONTAINER_NAME'..."
docker inspect "$CONTAINER_NAME" &>/dev/null \
  || error "Container '$CONTAINER_NAME' não encontrado."
STATUS=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Status}}')
[[ "$STATUS" != "running" ]] \
  && error "Container está '$STATUS'. Precisa estar 'running'."
success "Container rodando."

# ── 2. Conectividade MySQL ────────────────────────────────────────────────────
info "Testando conexão MySQL..."
sql "SELECT 1;" &>/dev/null || error "Falha na conexão. Verifique a senha."
success "Conexão OK."

# ── 3. Banco existe? ──────────────────────────────────────────────────────────
info "Verificando banco '$DB_NAME'..."
EXISTS=$(sql_s "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA \
  WHERE SCHEMA_NAME='${DB_NAME}';")
if [[ -z "$EXISTS" ]]; then
  warn "Banco '$DB_NAME' não encontrado."
  read -rp "  Deseja criá-lo agora? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] \
    || error "Banco não existe. Crie-o antes de continuar."
  sql "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  success "Banco '$DB_NAME' criado."
else
  success "Banco '$DB_NAME' encontrado."
fi

# ── 4. Verificar e corrigir Binary Log ───────────────────────────────────────
info "Verificando configuração do Binary Log..."

LOG_BIN=$(sql_s         "SHOW VARIABLES LIKE 'log_bin';"          | awk '{print $2}')
BINLOG_FMT=$(sql_s      "SHOW VARIABLES LIKE 'binlog_format';"    | awk '{print $2}')
BINLOG_DB=$(sql_s       "SHOW VARIABLES LIKE 'binlog_do_db';"     | awk '{print $2}')
CURRENT_SID=$(sql_s     "SHOW VARIABLES LIKE 'server_id';"        | awk '{print $2}')
CURRENT_RO=$(sql_s      "SHOW VARIABLES LIKE 'read_only';"        | awk '{print $2}')

NEEDS_RESTART=false

# read_only não deve estar ativo no master
if [[ "$CURRENT_RO" == "ON" ]]; then
  warn "read_only=ON detectado — master não deve ter read_only ativo. Será desativado."
  NEEDS_RESTART=true
fi

if [[ "$LOG_BIN" != "ON" ]] || [[ "$BINLOG_FMT" != "ROW" ]] \
    || [[ -n "$BINLOG_DB" ]] || [[ "$CURRENT_SID" != "$SERVER_ID" ]]; then

  [[ "$LOG_BIN" != "ON" ]]      && warn "Binary Log desativado — será ativado."
  [[ "$BINLOG_FMT" != "ROW" ]]  && warn "binlog_format=$BINLOG_FMT — será corrigido para ROW."
  [[ -n "$BINLOG_DB" ]]         && warn "binlog_do_db='$BINLOG_DB' detectado — causa perda de eventos. Será removido."
  [[ "$CURRENT_SID" != "$SERVER_ID" ]] \
    && warn "server-id atual ($CURRENT_SID) != esperado ($SERVER_ID) — será corrigido."

  NEEDS_RESTART=true
fi

if $NEEDS_RESTART; then
  info "Escrevendo /etc/mysql/conf.d/replication.cnf..."
  docker exec "$CONTAINER_NAME" bash -c "cat > /etc/mysql/conf.d/replication.cnf <<EOF
[mysqld]
server-id        = ${SERVER_ID}
log_bin          = mysql-bin
binlog_format    = ROW
expire_logs_days = 7
read_only        = OFF
super_read_only  = OFF
EOF"

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

  LOG_BIN=$(sql_s "SHOW VARIABLES LIKE 'log_bin';" | awk '{print $2}')
  [[ "$LOG_BIN" != "ON" ]] \
    && error "Binary Log ainda inativo após restart. Verifique o my.cnf manualmente."
  success "Binary Log confirmado ativo (ROW, server-id=$SERVER_ID)."
else
  success "Binary Log já configurado corretamente."
fi

# ── 5. Usuário de replicação ──────────────────────────────────────────────────
info "Configurando usuário de replicação '$REPLICA_USER'..."
EXISTS_USER=$(sql_s \
  "SELECT User FROM mysql.user WHERE User='${REPLICA_USER}' AND Host='%';")

if [[ -n "$EXISTS_USER" ]]; then
  warn "Usuário '$REPLICA_USER' já existe — atualizando senha e privilégios."
  sql "ALTER USER '${REPLICA_USER}'@'%'
    IDENTIFIED WITH mysql_native_password BY '${REPLICA_PASS}';"
else
  sql "CREATE USER '${REPLICA_USER}'@'%'
    IDENTIFIED WITH mysql_native_password BY '${REPLICA_PASS}';"
  success "Usuário '$REPLICA_USER' criado."
fi

sql "GRANT REPLICATION SLAVE ON *.* TO '${REPLICA_USER}'@'%';"
sql "FLUSH PRIVILEGES;"
success "Privilégios aplicados."

# ── 6. Dump + captura consistente do binlog ───────────────────────────────────
DUMP_FILE=""
BINLOG_FILE=""
BINLOG_POS=""

if ! $SKIP_DUMP; then
  DUMP_FILE="${DUMP_DIR}/mysql-dump-${DB_NAME}-$(date +%Y%m%d%H%M%S).sql"

  info "Travando tabelas para garantir consistência dump ↔ binlog..."
  sql "FLUSH TABLES WITH READ LOCK;"

  # Captura posição ANTES de soltar o lock (dentro da janela travada)
  MASTER_STATUS=$(sql_s "SHOW MASTER STATUS;")
  BINLOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
  BINLOG_POS=$(echo  "$MASTER_STATUS" | awk '{print $2}')

  [[ -z "$BINLOG_FILE" ]] && {
    sql "UNLOCK TABLES;"
    error "Não foi possível obter posição do binlog. Verifique se o Binary Log está ativo."
  }

  info "Posição capturada: $BINLOG_FILE @ $BINLOG_POS"
  info "Gerando dump do banco '$DB_NAME'..."

  docker exec "$CONTAINER_NAME" mysqldump \
    -uroot -p"${DB_PASSWORD}" \
    --single-transaction \
    --master-data=2 \
    --routines \
    --triggers \
    --events \
    "${DB_NAME}" > "$DUMP_FILE"

  # Libera o lock imediatamente
  sql "UNLOCK TABLES;"

  DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
  success "Dump salvo: $DUMP_FILE ($DUMP_SIZE)"
else
  warn "--skip-dump ativo: nenhum dump será gerado."
  info "Capturando posição atual do binlog..."
  MASTER_STATUS=$(sql_s "SHOW MASTER STATUS;")
  BINLOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
  BINLOG_POS=$(echo  "$MASTER_STATUS" | awk '{print $2}')
  [[ -z "$BINLOG_FILE" ]] && error "Não foi possível obter posição do binlog."
  success "Binlog: $BINLOG_FILE @ posição $BINLOG_POS"
fi

# ── 7. IP da máquina ──────────────────────────────────────────────────────────
MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$MY_IP" ]] && MY_IP="<IP desta máquina>"

# ── 8. Resumo final ───────────────────────────────────────────────────────────
SUMMARY="${DUMP_DIR}/mysql-master-${DB_NAME}-info.txt"
cat > "$SUMMARY" <<EOF
=== Master MySQL — ${DB_NAME} — $(date) ===

MASTER
  IP:               ${MY_IP}
  Porta:            ${MASTER_PORT}
  Container:        ${CONTAINER_NAME}
  Banco:            ${DB_NAME}
  server-id:        ${SERVER_ID}
  Binlog file:      ${BINLOG_FILE}
  Binlog posição:   ${BINLOG_POS}

CREDENCIAIS DE REPLICAÇÃO
  Usuário:          ${REPLICA_USER}
  Senha:            ${REPLICA_PASS}

DUMP GERADO
  Arquivo:          ${DUMP_FILE:-"(nenhum — --skip-dump ativo)"}

COMANDO PARA RODAR NA VM DA RÉPLICA
  # 1. Copie o dump para a réplica:
  scp ${DUMP_FILE:-"<arquivo.sql>"} usuario@<IP-REPLICA>:~/

  # 2. Configure a réplica:
  ./setup-mysql-replica.sh \\
    --db ${DB_NAME} \\
    --password ${DB_PASSWORD} \\
    --container <CONTAINER-REPLICA> \\
    --master-ip ${MY_IP} \\
    --master-port ${MASTER_PORT} \\
    --replica-user ${REPLICA_USER} \\
    --replica-pass ${REPLICA_PASS} \\
    --server-id 2 \\
    --dump ~/$(basename "${DUMP_FILE:-dump.sql}")

CHANGE MASTER TO (manual, caso necessário)
  STOP SLAVE;
  RESET SLAVE ALL;
  CHANGE MASTER TO
    MASTER_HOST     = '${MY_IP}',
    MASTER_PORT     = ${MASTER_PORT},
    MASTER_USER     = '${REPLICA_USER}',
    MASTER_PASSWORD = '${REPLICA_PASS}',
    MASTER_LOG_FILE = '${BINLOG_FILE}',
    MASTER_LOG_POS  = ${BINLOG_POS};
  START SLAVE;

COMANDOS ÚTEIS NO MASTER
  # Status do binlog:
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'SHOW MASTER STATUS\G'

  # Conexões ativas (monitorar réplicas conectadas):
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'SHOW PROCESSLIST\G'

  # Listar slaves conectados:
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'SHOW SLAVE HOSTS\G'
EOF

echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Master '${DB_NAME}' pronto para replicação!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
cat "$SUMMARY"
echo ""
success "Resumo salvo em: $SUMMARY"
echo ""