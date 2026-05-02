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
MASTER_IP=""
MASTER_PORT="3306"
REPLICA_PORT="3306"
REPLICA_USER="replicador"
REPLICA_PASS=""
SERVER_ID=2
DUMP_FILE=""
SKIP_DUMP=false

usage() {
  echo ""
  echo -e "${BOLD}Uso:${NC} $0 [opções]"
  echo ""
  echo "  --db              Nome do banco de dados"
  echo "  --password        Senha root do MySQL (réplica)"
  echo "  --container       Nome do container Docker da réplica"
  echo "  --master-ip       IP ou hostname do master"
  echo "  --master-port     Porta do master (padrão: 3306)"
  echo "  --replica-port    Porta da réplica (padrão: 3306)"
  echo "  --replica-user    Usuário de replicação (padrão: replicador)"
  echo "  --replica-pass    Senha do usuário de replicação"
  echo "  --server-id       server-id desta réplica (padrão: 2)"
  echo "  --dump            Caminho do arquivo .sql para importar antes de iniciar"
  echo "  --skip-dump       Pula a importação (assume dados já estão na réplica)"
  echo ""
  echo -e "${BOLD}Exemplos:${NC}"
  echo "  # Com dump (recomendado para bases com dados existentes):"
  echo "  $0 --db minha_base --password senha123 --container replica-mysql \\"
  echo "     --master-ip 192.168.1.10 --replica-pass replica123 \\"
  echo "     --dump ~/mysql-dump-minha_base-20240101120000.sql"
  echo ""
  echo "  # Sem dump (base vazia ou dados já importados manualmente):"
  echo "  $0 --db minha_base --password senha123 --container replica-mysql \\"
  echo "     --master-ip 192.168.1.10 --replica-pass replica123 --skip-dump"
  echo ""
  exit 1
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)            DB_NAME="$2";        shift 2 ;;
    --password)      DB_PASSWORD="$2";    shift 2 ;;
    --container)     CONTAINER_NAME="$2"; shift 2 ;;
    --master-ip)     MASTER_IP="$2";      shift 2 ;;
    --master-port)   MASTER_PORT="$2";    shift 2 ;;
    --replica-port)  REPLICA_PORT="$2";   shift 2 ;;
    --replica-user)  REPLICA_USER="$2";   shift 2 ;;
    --replica-pass)  REPLICA_PASS="$2";   shift 2 ;;
    --server-id)     SERVER_ID="$2";      shift 2 ;;
    --dump)          DUMP_FILE="$2";      shift 2 ;;
    --skip-dump)     SKIP_DUMP=true;      shift   ;;
    -h|--help) usage ;;
    *) error "Argumento desconhecido: $1" ;;
  esac
done

# ── Validações obrigatórias ────────────────────────────────────────────────────
[[ -z "$DB_NAME" ]]        && error "--db obrigatório"
[[ -z "$DB_PASSWORD" ]]    && error "--password obrigatório"
[[ -z "$CONTAINER_NAME" ]] && error "--container obrigatório"
[[ -z "$MASTER_IP" ]]      && error "--master-ip obrigatório"
[[ -z "$REPLICA_PASS" ]]   && error "--replica-pass obrigatório"

if ! $SKIP_DUMP && [[ -z "$DUMP_FILE" ]]; then
  warn "Nenhum --dump informado e --skip-dump não foi usado."
  warn "Replicação sem dump ignora dados existentes no master."
  read -rp "  Continuar mesmo assim? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || error "Operação cancelada. Informe --dump ou --skip-dump."
fi

if [[ -n "$DUMP_FILE" ]] && [[ ! -f "$DUMP_FILE" ]]; then
  error "Arquivo de dump não encontrado: $DUMP_FILE"
fi

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
info "  Master:    $MASTER_IP:$MASTER_PORT"
info "  Server-ID: $SERVER_ID"
[[ -n "$DUMP_FILE" ]] && info "  Dump:      $DUMP_FILE"
info "============================================================"
echo ""

# ── 1. Container existe e está rodando? ───────────────────────────────────────
info "Verificando container '$CONTAINER_NAME'..."
docker inspect "$CONTAINER_NAME" &>/dev/null || error "Container '$CONTAINER_NAME' não encontrado."
STATUS=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Status}}')
[[ "$STATUS" != "running" ]] && error "Container está '$STATUS'. Precisa estar 'running'."
success "Container rodando."

# ── 2. Conectividade MySQL ────────────────────────────────────────────────────
info "Testando conexão MySQL na réplica..."
sql "SELECT 1;" &>/dev/null || error "Falha na conexão. Verifique a senha e o container."
success "Conexão OK."

# ── 3. Configurar server-id e relay log ──────────────────────────────────────
info "Verificando configuração de replicação..."
CURRENT_SERVER_ID=$(sql_s "SHOW VARIABLES LIKE 'server_id';" | awk '{print $2}')
RELAY_LOG_OK=$(sql_s "SHOW VARIABLES LIKE 'relay_log';" | awk '{print $2}')

if [[ "$CURRENT_SERVER_ID" != "$SERVER_ID" ]] || [[ -z "$RELAY_LOG_OK" ]]; then
  warn "Configuração incompleta — aplicando /etc/mysql/conf.d/replica.cnf..."
  docker exec "$CONTAINER_NAME" bash -c "cat > /etc/mysql/conf.d/replica.cnf <<EOF
[mysqld]
server-id              = ${SERVER_ID}
relay_log              = relay-bin
log_bin                = mysql-bin
binlog_format          = ROW
read_only              = ON
super_read_only        = ON
expire_logs_days       = 7
slave_skip_errors      = OFF
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

  CURRENT_SERVER_ID=$(sql_s "SHOW VARIABLES LIKE 'server_id';" | awk '{print $2}')
  [[ "$CURRENT_SERVER_ID" != "$SERVER_ID" ]] && \
    error "server-id ainda incorreto após restart ($CURRENT_SERVER_ID). Verifique my.cnf."
  success "server-id=$SERVER_ID confirmado."
else
  success "server-id=$SERVER_ID já configurado."
fi

# ── 4. Parar slave caso esteja rodando ───────────────────────────────────────
info "Parando slave (se ativo)..."
sql "STOP SLAVE;" 2>/dev/null || true
sql "RESET SLAVE ALL;" 2>/dev/null || true
success "Slave resetado."

# ── 5. Criar banco se não existir ─────────────────────────────────────────────
info "Verificando banco '$DB_NAME'..."
EXISTS=$(sql_s "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")
if [[ -z "$EXISTS" ]]; then
  info "Banco '$DB_NAME' não existe — criando..."
  sql "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  success "Banco '$DB_NAME' criado."
else
  success "Banco '$DB_NAME' encontrado."
fi

# ── 6. Importar dump ─────────────────────────────────────────────────────────
if [[ -n "$DUMP_FILE" ]] && ! $SKIP_DUMP; then
  DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
  info "Importando dump ($DUMP_SIZE) — isso pode demorar..."

  # Desabilita checagens para import mais rápido
  docker exec -i "$CONTAINER_NAME" mysql \
    -uroot -p"${DB_PASSWORD}" \
    --init-command="SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0;" \
    "$DB_NAME" < "$DUMP_FILE" \
    || error "Falha ao importar dump. Verifique o arquivo e tente novamente."

  success "Dump importado com sucesso."

  # Tenta extrair a posição do binlog do --master-data=2
  BINLOG_FILE_FROM_DUMP=$(grep -m1 "MASTER_LOG_FILE" "$DUMP_FILE" 2>/dev/null \
    | grep -oP "(?<=MASTER_LOG_FILE=')[^']*" || true)
  BINLOG_POS_FROM_DUMP=$(grep -m1 "MASTER_LOG_POS"  "$DUMP_FILE" 2>/dev/null \
    | grep -oP "(?<=MASTER_LOG_POS=)\d+" || true)

  if [[ -n "$BINLOG_FILE_FROM_DUMP" ]] && [[ -n "$BINLOG_POS_FROM_DUMP" ]]; then
    info "Posição do binlog detectada no dump:"
    info "  Arquivo:  $BINLOG_FILE_FROM_DUMP"
    info "  Posição:  $BINLOG_POS_FROM_DUMP"
    BINLOG_FILE="$BINLOG_FILE_FROM_DUMP"
    BINLOG_POS="$BINLOG_POS_FROM_DUMP"
  else
    warn "Dump sem --master-data=2. Será necessário informar binlog manualmente."
    echo ""
    read -rp "  Arquivo do binlog (ex: mysql-bin.000001): " BINLOG_FILE
    read -rp "  Posição do binlog (ex: 154):               " BINLOG_POS
    [[ -z "$BINLOG_FILE" ]] && error "Arquivo do binlog não informado."
    [[ -z "$BINLOG_POS"  ]] && error "Posição do binlog não informada."
  fi
else
  if $SKIP_DUMP; then
    warn "--skip-dump ativo: nenhum dado será importado."
  fi

  # Sem dump: pergunta posição manualmente
  echo ""
  warn "Informe a posição do binlog do master (resultado de SHOW MASTER STATUS):"
  read -rp "  Arquivo do binlog (ex: mysql-bin.000001): " BINLOG_FILE
  read -rp "  Posição do binlog (ex: 154):               " BINLOG_POS
  [[ -z "$BINLOG_FILE" ]] && error "Arquivo do binlog não informado."
  [[ -z "$BINLOG_POS"  ]] && error "Posição do binlog não informada."
fi

# ── 7. Configurar e iniciar replicação ───────────────────────────────────────
info "Configurando CHANGE MASTER TO..."
sql "
  CHANGE MASTER TO
    MASTER_HOST     = '${MASTER_IP}',
    MASTER_PORT     = ${MASTER_PORT},
    MASTER_USER     = '${REPLICA_USER}',
    MASTER_PASSWORD = '${REPLICA_PASS}',
    MASTER_LOG_FILE = '${BINLOG_FILE}',
    MASTER_LOG_POS  = ${BINLOG_POS};
"

info "Iniciando slave..."
sql "START SLAVE;"
success "Slave iniciado."

# ── 8. Validação da replicação ────────────────────────────────────────────────
info "Aguardando inicialização do slave (5s)..."
sleep 5

SLAVE_STATUS=$(sql_s "SHOW SLAVE STATUS\G" 2>/dev/null || true)

IO_RUNNING=$(echo  "$SLAVE_STATUS" | grep "Slave_IO_Running:"  | awk '{print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
LAST_ERROR=$(echo  "$SLAVE_STATUS" | grep "Last_Error:"        | sed 's/.*Last_Error: //')
SECONDS_BEHIND=$(echo "$SLAVE_STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')

echo ""
if [[ "$IO_RUNNING" == "Yes" ]] && [[ "$SQL_RUNNING" == "Yes" ]]; then
  success "Slave_IO_Running:  Yes"
  success "Slave_SQL_Running: Yes"
  [[ -n "$SECONDS_BEHIND" ]] && info "Seconds_Behind_Master: $SECONDS_BEHIND"
else
  warn "Slave_IO_Running:  $IO_RUNNING"
  warn "Slave_SQL_Running: $SQL_RUNNING"
  [[ -n "$LAST_ERROR" ]] && [[ "$LAST_ERROR" != "" ]] && \
    error "Erro de replicação: $LAST_ERROR"
fi

# ── 9. Resumo final ───────────────────────────────────────────────────────────
MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$MY_IP" ]] && MY_IP="<IP desta máquina>"

SUMMARY="$HOME/mysql-replica-${DB_NAME}-info.txt"
cat > "$SUMMARY" <<EOF
=== Réplica MySQL — ${DB_NAME} — $(date) ===

MASTER
  IP:               ${MASTER_IP}
  Porta:            ${MASTER_PORT}
  Binlog file:      ${BINLOG_FILE}
  Binlog posição:   ${BINLOG_POS}

RÉPLICA
  IP:               ${MY_IP}
  Porta:            ${REPLICA_PORT}
  Container:        ${CONTAINER_NAME}
  Banco:            ${DB_NAME}
  server-id:        ${SERVER_ID}
  read_only:        ON

CREDENCIAIS DE REPLICAÇÃO
  Usuário:          ${REPLICA_USER}
  Senha:            ${REPLICA_PASS}

DUMP IMPORTADO
  Arquivo:          ${DUMP_FILE:-"(nenhum)"}

COMANDOS ÚTEIS
  # Verificar status da réplica:
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'SHOW SLAVE STATUS\G'

  # Verificar lag:
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} \
    -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind_Master

  # Parar replicação:
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'STOP SLAVE;'

  # Reiniciar replicação:
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} -e 'START SLAVE;'

  # Pular um erro pontual (com cuidado!):
  docker exec ${CONTAINER_NAME} mysql -uroot -p${DB_PASSWORD} \
    -e 'STOP SLAVE; SET GLOBAL SQL_SLAVE_SKIP_COUNTER=1; START SLAVE;'
EOF

echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
if [[ "$IO_RUNNING" == "Yes" ]] && [[ "$SQL_RUNNING" == "Yes" ]]; then
  echo -e "${GREEN}${BOLD}  Réplica '${DB_NAME}' configurada e ativa!${NC}"
else
  echo -e "${YELLOW}${BOLD}  Réplica configurada — verifique os erros acima.${NC}"
fi
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
cat "$SUMMARY"
echo ""
success "Arquivo salvo em: $SUMMARY"
echo ""