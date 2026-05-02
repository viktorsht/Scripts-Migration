#!/bin/bash
# =============================================================================
#  mysql-migrate.sh — Orquestrador completo de replicação MySQL via Docker
#  Uso: ./mysql-migrate.sh migration.json
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }
dim()     { echo -e "${DIM}$*${NC}"; }

# ── Dependências ───────────────────────────────────────────────────────────────
for cmd in ssh scp jq docker; do
  command -v "$cmd" &>/dev/null || error "Dependência não encontrada: '$cmd'. Instale e tente novamente."
done

# ── Argumento ──────────────────────────────────────────────────────────────────
CONFIG="${1:-}"
[[ -z "$CONFIG" ]]    && { echo "Uso: $0 <migration.json>"; exit 1; }
[[ ! -f "$CONFIG" ]]  && error "Arquivo não encontrado: $CONFIG"

# Valida JSON
jq empty "$CONFIG" 2>/dev/null || error "JSON inválido: $CONFIG"

# ── Leitura do JSON ────────────────────────────────────────────────────────────
M_HOST=$(jq -r '.master.host'          "$CONFIG")
M_USER=$(jq -r '.master.ssh_user'      "$CONFIG")
M_KEY=$(jq  -r '.master.ssh_key'       "$CONFIG")
M_KEY="${M_KEY/#\~/$HOME}"
M_CONTAINER=$(jq -r '.master.container'   "$CONFIG")
M_PORT=$(jq  -r '.master.port'         "$CONFIG")
M_PASS=$(jq  -r '.master.root_password'"$CONFIG")
M_PASS=$(jq  -r '.master.root_password' "$CONFIG")
M_DB=$(jq    -r '.master.db'           "$CONFIG")
M_SID=$(jq   -r '.master.server_id'    "$CONFIG")
M_DUMP_DIR=$(jq -r '.master.dump_dir'  "$CONFIG")

R_HOST=$(jq -r '.replica.host'          "$CONFIG")
R_USER=$(jq -r '.replica.ssh_user'      "$CONFIG")
R_KEY=$(jq  -r '.replica.ssh_key'       "$CONFIG")
R_KEY="${R_KEY/#\~/$HOME}"
R_CONTAINER=$(jq -r '.replica.container'   "$CONFIG")
R_PORT=$(jq  -r '.replica.port'         "$CONFIG")
R_PASS=$(jq  -r '.replica.root_password' "$CONFIG")
R_DB=$(jq    -r '.replica.db'           "$CONFIG")
R_SID=$(jq   -r '.replica.server_id'    "$CONFIG")
R_IMAGE=$(jq -r '.replica.mysql_image'  "$CONFIG")

REP_USER=$(jq -r '.replication.user'     "$CONFIG")
REP_PASS=$(jq -r '.replication.password' "$CONFIG")

# SSH helpers (executa comando remoto silenciosamente, capturando stderr)
ssh_exec() {
  local host="$1"; local user="$2"; local key="$3"; shift 3
  ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${user}@${host}" "$@" 2>&1
}
ssh_exec_raw() {
  local host="$1"; local user="$2"; local key="$3"; shift 3
  ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${user}@${host}" "$@"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         MySQL Migration Orchestrator                     ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Master:${NC}   ${M_USER}@${M_HOST} → container '${M_CONTAINER}' → banco '${M_DB}'"
echo -e "  ${BOLD}Réplica:${NC}  ${R_USER}@${R_HOST} → container '${R_CONTAINER}' → banco '${R_DB}'"
echo -e "  ${BOLD}Config:${NC}   $CONFIG"
echo ""
read -rp "  Confirma execução completa? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# =============================================================================
#  FASE 1 — VERIFICAR CONECTIVIDADE SSH
# =============================================================================
step "FASE 1 — Verificando conectividade SSH"

info "Testando SSH no master ($M_HOST)..."
ssh_exec "$M_HOST" "$M_USER" "$M_KEY" "echo ok" | grep -q "ok" \
  || error "SSH no master falhou. Verifique host, usuário e chave: $M_KEY"
success "SSH master OK."

info "Testando SSH na réplica ($R_HOST)..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" "echo ok" | grep -q "ok" \
  || error "SSH na réplica falhou. Verifique host, usuário e chave: $R_KEY"
success "SSH réplica OK."

# =============================================================================
#  FASE 2 — VERIFICAR DOCKER NAS DUAS VMs
# =============================================================================
step "FASE 2 — Verificando Docker"

info "Docker no master..."
ssh_exec "$M_HOST" "$M_USER" "$M_KEY" "docker info > /dev/null 2>&1 && echo ok" \
  | grep -q "ok" || error "Docker não disponível no master."
success "Docker master OK."

info "Docker na réplica..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" "docker info > /dev/null 2>&1 && echo ok" \
  | grep -q "ok" || error "Docker não disponível na réplica."
success "Docker réplica OK."

# =============================================================================
#  FASE 3 — GARANTIR CONTAINER MYSQL NA RÉPLICA
# =============================================================================
step "FASE 3 — Container MySQL na réplica"

R_STATUS=$(ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker inspect ${R_CONTAINER} --format='{{.State.Status}}' 2>/dev/null || echo 'absent'")

case "$R_STATUS" in
  running)
    success "Container '${R_CONTAINER}' já está rodando."
    ;;
  absent|"")
    info "Container '${R_CONTAINER}' não existe — criando com imagem '${R_IMAGE}'..."
    ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
      "docker run -d \
        --name ${R_CONTAINER} \
        --restart unless-stopped \
        -e MYSQL_ROOT_PASSWORD=${R_PASS} \
        -e MYSQL_DATABASE=${R_DB} \
        -p ${R_PORT}:3306 \
        ${R_IMAGE}" | dim
    success "Container criado."
    ;;
  exited|stopped|created)
    info "Container '${R_CONTAINER}' está '$R_STATUS' — iniciando..."
    ssh_exec "$R_HOST" "$R_USER" "$R_KEY" "docker start ${R_CONTAINER}" | dim
    ;;
  *)
    error "Estado inesperado do container na réplica: $R_STATUS"
    ;;
esac

info "Aguardando MySQL na réplica ficar disponível..."
for i in $(seq 1 40); do
  PING=$(ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
    "docker exec ${R_CONTAINER} mysqladmin ping \
      -uroot -p${R_PASS} --silent 2>/dev/null && echo pong || true")
  [[ "$PING" == *"pong"* ]] && break
  [[ $i -eq 40 ]] && error "MySQL na réplica não respondeu após 80s."
  sleep 2
done
success "MySQL na réplica respondendo."

# Desativa read_only caso venha ativo por padrão na imagem
info "Desativando read_only na réplica (se ativo)..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} \
    -e 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;' 2>/dev/null || true" | dim
success "read_only desativado."

# =============================================================================
#  FASE 4 — CONFIGURAR MASTER (binlog, server-id, usuário de replicação)
# =============================================================================
step "FASE 4 — Configurando master"

info "Verificando container master '${M_CONTAINER}'..."
M_STATUS=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker inspect ${M_CONTAINER} --format='{{.State.Status}}' 2>/dev/null || echo 'absent'")
[[ "$M_STATUS" != "running" ]] \
  && error "Container master '${M_CONTAINER}' não está running (status: $M_STATUS)."
success "Container master rodando."

# Checa se precisa reconfigurar
LOG_BIN=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'log_bin';\" 2>/dev/null | awk '{print \$2}'")
BINLOG_FMT=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'binlog_format';\" 2>/dev/null | awk '{print \$2}'")
CURRENT_SID=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'server_id';\" 2>/dev/null | awk '{print \$2}'")
CURRENT_RO=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'read_only';\" 2>/dev/null | awk '{print \$2}'")

NEEDS_RESTART=false
[[ "$LOG_BIN" != "ON" ]]              && { warn "Binary Log inativo — será ativado.";           NEEDS_RESTART=true; }
[[ "$BINLOG_FMT" != "ROW" ]]         && { warn "binlog_format=$BINLOG_FMT — corrigindo.";      NEEDS_RESTART=true; }
[[ "$CURRENT_SID" != "$M_SID" ]]     && { warn "server-id incorreto ($CURRENT_SID) — corrigindo."; NEEDS_RESTART=true; }
[[ "$CURRENT_RO" == "ON" ]]          && { warn "read_only=ON no master — desativando.";         NEEDS_RESTART=true; }

if $NEEDS_RESTART; then
  info "Escrevendo replication.cnf no master..."
  ssh_exec "$M_HOST" "$M_USER" "$M_KEY" "
    docker exec ${M_CONTAINER} bash -c \"cat > /etc/mysql/conf.d/replication.cnf <<EOF
[mysqld]
server-id        = ${M_SID}
log_bin          = mysql-bin
binlog_format    = ROW
expire_logs_days = 7
read_only        = OFF
super_read_only  = OFF
EOF\"" | dim

  info "Reiniciando container master..."
  ssh_exec "$M_HOST" "$M_USER" "$M_KEY" "docker restart ${M_CONTAINER}" | dim

  info "Aguardando MySQL master reiniciar..."
  for i in $(seq 1 30); do
    PING=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
      "docker exec ${M_CONTAINER} mysqladmin ping \
        -uroot -p${M_PASS} --silent 2>/dev/null && echo pong || true")
    [[ "$PING" == *"pong"* ]] && break
    [[ $i -eq 30 ]] && error "MySQL master não voltou após restart."
    sleep 2
  done
  success "Master reiniciado."
else
  success "Master já configurado corretamente."
fi

# Usuário de replicação
info "Configurando usuário de replicação '${REP_USER}'..."
EXISTS_USER=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} --silent \
    -e \"SELECT User FROM mysql.user WHERE User='${REP_USER}' AND Host='%';\" 2>/dev/null")

if [[ -n "$EXISTS_USER" ]]; then
  warn "Usuário '${REP_USER}' já existe — atualizando senha."
  ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
    "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} \
      -e \"ALTER USER '${REP_USER}'@'%'
        IDENTIFIED WITH mysql_native_password BY '${REP_PASS}';\" 2>/dev/null" | dim
else
  ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
    "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} \
      -e \"CREATE USER '${REP_USER}'@'%'
        IDENTIFIED WITH mysql_native_password BY '${REP_PASS}';\" 2>/dev/null" | dim
fi
ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} \
    -e \"GRANT REPLICATION SLAVE ON *.* TO '${REP_USER}'@'%';
         FLUSH PRIVILEGES;\" 2>/dev/null" | dim
success "Usuário '${REP_USER}' configurado."

# =============================================================================
#  FASE 5 — DUMP CONSISTENTE (lock → posição binlog → dump → unlock)
# =============================================================================
step "FASE 5 — Gerando dump consistente"

DUMP_NAME="mysql-dump-${M_DB}-$(date +%Y%m%d%H%M%S).sql"
DUMP_PATH="${M_DUMP_DIR}/${DUMP_NAME}"

info "Travando tabelas no master..."
ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} \
    -e 'FLUSH TABLES WITH READ LOCK;' 2>/dev/null" | dim

info "Capturando posição do binlog..."
MASTER_STATUS=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} --silent \
    -e 'SHOW MASTER STATUS;' 2>/dev/null")
BINLOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
BINLOG_POS=$(echo  "$MASTER_STATUS" | awk '{print $2}')

if [[ -z "$BINLOG_FILE" ]]; then
  ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
    "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} \
      -e 'UNLOCK TABLES;' 2>/dev/null" | dim
  error "Não foi possível capturar posição do binlog."
fi

info "Binlog: ${BINLOG_FILE} @ posição ${BINLOG_POS}"
info "Gerando dump de '${M_DB}'..."

ssh_exec_raw "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysqldump \
    -uroot -p${M_PASS} \
    --single-transaction \
    --master-data=2 \
    --routines \
    --triggers \
    --events \
    ${M_DB} > ${DUMP_PATH} 2>/dev/null"

info "Liberando lock..."
ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} \
    -e 'UNLOCK TABLES;' 2>/dev/null" | dim

DUMP_SIZE=$(ssh_exec "$M_HOST" "$M_USER" "$M_KEY" \
  "du -sh ${DUMP_PATH} | cut -f1")
success "Dump gerado: ${DUMP_PATH} (${DUMP_SIZE})"

# =============================================================================
#  FASE 6 — TRANSFERIR DUMP PARA RÉPLICA
# =============================================================================
step "FASE 6 — Transferindo dump para réplica"

R_DUMP_PATH="/home/${R_USER}/${DUMP_NAME}"

info "Copiando via SCP: master → réplica..."
# Copia do master para a máquina local (orquestrador) e depois para a réplica
TMP_DUMP="/tmp/${DUMP_NAME}"
scp -i "$M_KEY" -o StrictHostKeyChecking=no \
  "${M_USER}@${M_HOST}:${DUMP_PATH}" "$TMP_DUMP"

scp -i "$R_KEY" -o StrictHostKeyChecking=no \
  "$TMP_DUMP" "${R_USER}@${R_HOST}:${R_DUMP_PATH}"

rm -f "$TMP_DUMP"
success "Dump transferido para réplica: ${R_DUMP_PATH}"

# =============================================================================
#  FASE 7 — IMPORTAR DUMP NA RÉPLICA
# =============================================================================
step "FASE 7 — Importando dump na réplica"

# Garante que o banco existe
info "Garantindo banco '${R_DB}' na réplica..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} \
    -e \"CREATE DATABASE IF NOT EXISTS \\\`${R_DB}\\\`
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\" 2>/dev/null" | dim

info "Importando dump (${DUMP_SIZE})..."
ssh_exec_raw "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec -i ${R_CONTAINER} mysql \
    -uroot -p${R_PASS} \
    --init-command='SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0;' \
    ${R_DB} < ${R_DUMP_PATH}"

success "Dump importado com sucesso."

# =============================================================================
#  FASE 8 — CONFIGURAR REPLICAÇÃO NA RÉPLICA
# =============================================================================
step "FASE 8 — Configurando replicação na réplica"

info "Escrevendo replica.cnf..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" "
  docker exec ${R_CONTAINER} bash -c \"cat > /etc/mysql/conf.d/replica.cnf <<EOF
[mysqld]
server-id              = ${R_SID}
relay_log              = relay-bin
log_bin                = mysql-bin
binlog_format          = ROW
read_only              = ON
super_read_only        = ON
expire_logs_days       = 7
EOF\"" | dim

info "Reiniciando container da réplica para aplicar configurações..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" "docker restart ${R_CONTAINER}" | dim

info "Aguardando MySQL da réplica reiniciar..."
for i in $(seq 1 40); do
  PING=$(ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
    "docker exec ${R_CONTAINER} mysqladmin ping \
      -uroot -p${R_PASS} --silent 2>/dev/null && echo pong || true")
  [[ "$PING" == *"pong"* ]] && break
  [[ $i -eq 40 ]] && error "MySQL da réplica não voltou após restart."
  sleep 2
done
success "Réplica reiniciada."

info "Parando slave anterior (se existir)..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} \
    -e 'STOP SLAVE; RESET SLAVE ALL;' 2>/dev/null || true" | dim

info "Executando CHANGE MASTER TO..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} -e \"
    CHANGE MASTER TO
      MASTER_HOST     = '${M_HOST}',
      MASTER_PORT     = ${M_PORT},
      MASTER_USER     = '${REP_USER}',
      MASTER_PASSWORD = '${REP_PASS}',
      MASTER_LOG_FILE = '${BINLOG_FILE}',
      MASTER_LOG_POS  = ${BINLOG_POS};
  \" 2>/dev/null" | dim

info "Iniciando slave..."
ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} \
    -e 'START SLAVE;' 2>/dev/null" | dim

# =============================================================================
#  FASE 9 — VALIDAÇÃO FINAL
# =============================================================================
step "FASE 9 — Validando replicação"

info "Aguardando slave estabilizar (5s)..."
sleep 5

SLAVE_STATUS=$(ssh_exec "$R_HOST" "$R_USER" "$R_KEY" \
  "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} \
    -e 'SHOW SLAVE STATUS\G' 2>/dev/null")

IO_RUNNING=$(echo  "$SLAVE_STATUS" | grep "Slave_IO_Running:"  | awk '{print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
LAST_ERROR=$(echo  "$SLAVE_STATUS" | grep "Last_Error:"        | sed 's/.*Last_Error: //')
SECONDS_BH=$(echo  "$SLAVE_STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')

echo ""
if [[ "$IO_RUNNING" == "Yes" ]] && [[ "$SQL_RUNNING" == "Yes" ]]; then
  success "Slave_IO_Running:      Yes"
  success "Slave_SQL_Running:     Yes"
  info    "Seconds_Behind_Master: ${SECONDS_BH:-0}"
else
  warn "Slave_IO_Running:  ${IO_RUNNING:-?}"
  warn "Slave_SQL_Running: ${SQL_RUNNING:-?}"
  [[ -n "$LAST_ERROR" ]] && warn "Last_Error: $LAST_ERROR"
fi

# =============================================================================
#  FASE 10 — RESUMO E LIMPEZA
# =============================================================================
step "FASE 10 — Resumo"

SUMMARY_FILE="./migration-summary-$(date +%Y%m%d%H%M%S).txt"
cat > "$SUMMARY_FILE" <<EOF
=== Migração MySQL — $(date) ===

MASTER
  Host:             ${M_HOST}
  Container:        ${M_CONTAINER}
  Banco:            ${M_DB}
  server-id:        ${M_SID}
  Porta:            ${M_PORT}
  Binlog file:      ${BINLOG_FILE}
  Binlog posição:   ${BINLOG_POS}

RÉPLICA
  Host:             ${R_HOST}
  Container:        ${R_CONTAINER}
  Banco:            ${R_DB}
  server-id:        ${R_SID}
  Porta:            ${R_PORT}
  read_only:        ON

REPLICAÇÃO
  Usuário:          ${REP_USER}
  IO Running:       ${IO_RUNNING:-?}
  SQL Running:      ${SQL_RUNNING:-?}
  Lag (segundos):   ${SECONDS_BH:-0}

DUMP
  Gerado em:        ${M_HOST}:${DUMP_PATH}
  Importado em:     ${R_HOST}:${R_DUMP_PATH}
  Tamanho:          ${DUMP_SIZE}

COMANDOS ÚTEIS
  # Status da réplica:
  ssh ${R_USER}@${R_HOST} "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} -e 'SHOW SLAVE STATUS\G'"

  # Lag atual:
  ssh ${R_USER}@${R_HOST} "docker exec ${R_CONTAINER} mysql -uroot -p${R_PASS} -e 'SHOW SLAVE STATUS\G'" | grep Seconds_Behind

  # Slaves conectados no master:
  ssh ${M_USER}@${M_HOST} "docker exec ${M_CONTAINER} mysql -uroot -p${M_PASS} -e 'SHOW SLAVE HOSTS\G'"
EOF

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
if [[ "$IO_RUNNING" == "Yes" ]] && [[ "$SQL_RUNNING" == "Yes" ]]; then
  echo -e "${GREEN}${BOLD}║   Migração concluída com sucesso!                        ║${NC}"
else
  echo -e "${YELLOW}${BOLD}║   Migração concluída com avisos — verifique o slave.     ║${NC}"
fi
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
cat "$SUMMARY_FILE"
echo ""
success "Resumo salvo em: $SUMMARY_FILE"
echo ""