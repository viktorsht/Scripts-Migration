#!/bin/bash
# =============================================================================
#  mysql-migrate.sh — Orquestrador completo de migração MySQL + API
#
#  Fluxo:
#    0.  Gera chave SSH dedicada (keys/ssh_migration_key) e distribui para VMs
#    1.  Valida SSH e Docker nas duas VMs
#    2.  Garante container MySQL na réplica
#    3.  Configura master (binlog, server-id, usuário de replicação)
#    4.  Dump consistente (lock → binlog → dump → unlock)
#    5.  Transfere dump para a réplica
#    6.  Importa dump na réplica
#    7.  Configura e inicia replicação MySQL
#    8.  Valida replicação (IO + SQL running)
#    9.  Clona repo, build e sobe API na réplica
#    10. Health-check da API na réplica
#    11. Para e remove API + banco na origem
#
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
dim()     { echo -e "${DIM}    $*${NC}"; }

# ── Dependências locais ────────────────────────────────────────────────────────
for cmd in ssh scp ssh-keygen ssh-copy-id jq curl; do
  command -v "$cmd" &>/dev/null \
    || error "Dependência não encontrada: '$cmd'. Instale e tente novamente."
done

# ── Argumento ──────────────────────────────────────────────────────────────────
CONFIG="${1:-}"
[[ -z "$CONFIG" ]]   && { echo "Uso: $0 <migration.json>"; exit 1; }
[[ ! -f "$CONFIG" ]] && error "Arquivo não encontrado: $CONFIG"
jq empty "$CONFIG" 2>/dev/null || error "JSON inválido: $CONFIG"

# ── Leitura do JSON ────────────────────────────────────────────────────────────
jp() { jq -r "$1" "$CONFIG"; }

M_HOST=$(jp    '.master.host')
M_USER=$(jp    '.master.ssh_user')
M_DBC=$(jp     '.master.db_container')
M_APIC=$(jp    '.master.api_container')
M_DBPORT=$(jp  '.master.db_port')
M_APIPORT=$(jp '.master.api_port')
M_PASS=$(jp    '.master.root_password')
M_DB=$(jp      '.master.db')
M_SID=$(jp     '.master.server_id')
M_DUMPDIR=$(jp '.master.dump_dir')

R_HOST=$(jp    '.replica.host')
R_USER=$(jp    '.replica.ssh_user')
R_DBC=$(jp     '.replica.db_container')
R_APIC=$(jp    '.replica.api_container')
R_DBPORT=$(jp  '.replica.db_port')
R_APIPORT=$(jp '.replica.api_port')
R_PASS=$(jp    '.replica.root_password')
R_DB=$(jp      '.replica.db')
R_SID=$(jp     '.replica.server_id')
R_IMAGE=$(jp   '.replica.mysql_image')

API_REPO=$(jp   '.api.repo')
API_IMAGE=$(jp  '.api.image')
API_DBUSER=$(jp '.api.db_user')
API_DBPASS=$(jp '.api.db_password')
API_DBNAME=$(jp '.api.db_name')

REP_USER=$(jp '.replication.user')
REP_PASS=$(jp '.replication.password')

REPO_DIR=$(basename "$API_REPO" .git)

# ── Chave SSH dedicada ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
SSH_KEY="${KEYS_DIR}/ssh_migration_key"

# ── SSH helpers ────────────────────────────────────────────────────────────────
ssh_run() {
  local host="$1" user="$2"; shift 2
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o PasswordAuthentication=no \
      "${user}@${host}" "$@" 2>&1
}
ssh_live() {
  local host="$1" user="$2"; shift 2
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o PasswordAuthentication=no \
      "${user}@${host}" "$@"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║        MySQL + API Migration Orchestrator                ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Origem:${NC}   ${M_USER}@${M_HOST}"
echo -e "            banco '${M_DBC}'  •  api '${M_APIC}'"
echo -e "  ${BOLD}Destino:${NC}  ${R_USER}@${R_HOST}"
echo -e "            banco '${R_DBC}'  •  api '${R_APIC}'"
echo -e "  ${BOLD}Repo API:${NC} ${API_REPO}"
echo -e "  ${BOLD}Config:${NC}   ${CONFIG}"
echo ""
warn "Ao final, a API e o banco da ORIGEM serão PARADOS e REMOVIDOS."
echo ""
read -rp "  Confirma execução completa? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# =============================================================================
#  FASE 0 — CHAVE SSH DEDICADA
# =============================================================================
step "FASE 0/11 — Configurando chave SSH dedicada"

mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

if [[ -f "$SSH_KEY" ]]; then
  success "Chave já existe: ${SSH_KEY}"
else
  info "Gerando chave SSH dedicada em '${SSH_KEY}'..."
  ssh-keygen -t ed25519 \
    -f "$SSH_KEY" \
    -C "mysql-migration-$(date +%Y%m%d)" \
    -N "" -q
  success "Chave gerada."
fi

info "Chave pública:"
dim "$(cat "${SSH_KEY}.pub")"

echo ""
warn "A chave pública precisa ser copiada para as duas VMs."
warn "Você precisará digitar a senha SSH de cada VM UMA VEZ agora."
echo ""

info "Copiando chave para o master (${M_USER}@${M_HOST})..."
ssh-copy-id -i "${SSH_KEY}.pub" \
  -o StrictHostKeyChecking=no \
  "${M_USER}@${M_HOST}" \
  || error "Falha ao copiar chave para o master. Verifique usuário e host."
success "Chave instalada no master."

info "Copiando chave para a réplica (${R_USER}@${R_HOST})..."
ssh-copy-id -i "${SSH_KEY}.pub" \
  -o StrictHostKeyChecking=no \
  "${R_USER}@${R_HOST}" \
  || error "Falha ao copiar chave para a réplica. Verifique usuário e host."
success "Chave instalada na réplica."

# =============================================================================
#  FASE 1 — CONECTIVIDADE SSH (sem senha)
# =============================================================================
step "FASE 1/11 — Verificando conectividade SSH"

info "SSH master ($M_HOST)..."
ssh_run "$M_HOST" "$M_USER" "echo ok" | grep -q "ok" \
  || error "SSH no master falhou mesmo após instalar a chave."
success "SSH master OK (sem senha)."

info "SSH réplica ($R_HOST)..."
ssh_run "$R_HOST" "$R_USER" "echo ok" | grep -q "ok" \
  || error "SSH na réplica falhou mesmo após instalar a chave."
success "SSH réplica OK (sem senha)."

# =============================================================================
#  FASE 2 — DOCKER NAS DUAS VMs
# =============================================================================
step "FASE 2/11 — Verificando Docker"

for role in master replica; do
  [[ "$role" == "master" ]] && h=$M_HOST u=$M_USER || h=$R_HOST u=$R_USER
  info "Docker no $role ($h)..."
  ssh_run "$h" "$u" "docker info > /dev/null 2>&1 && echo ok" \
    | grep -q "ok" || error "Docker não disponível no $role ($h)."
  success "Docker $role OK."
done

# =============================================================================
#  FASE 3 — GARANTIR CONTAINER MYSQL NA RÉPLICA
# =============================================================================
step "FASE 3/11 — Container MySQL na réplica"

R_STATUS=$(ssh_run "$R_HOST" "$R_USER" \
  "docker inspect ${R_DBC} --format='{{.State.Status}}' 2>/dev/null || echo absent")

case "$R_STATUS" in
  running)
    success "Container '${R_DBC}' já está rodando."
    ;;
  absent|"")
    info "Container '${R_DBC}' não existe — criando com imagem '${R_IMAGE}'..."
    ssh_run "$R_HOST" "$R_USER" \
      "docker run -d \
        --name ${R_DBC} \
        --restart unless-stopped \
        -e MYSQL_ROOT_PASSWORD=${R_PASS} \
        -e MYSQL_DATABASE=${R_DB} \
        -p ${R_DBPORT}:3306 \
        ${R_IMAGE}" | while read -r l; do dim "$l"; done
    success "Container '${R_DBC}' criado."
    ;;
  exited|stopped|created)
    info "Container '${R_DBC}' está '${R_STATUS}' — iniciando..."
    ssh_run "$R_HOST" "$R_USER" "docker start ${R_DBC}" \
      | while read -r l; do dim "$l"; done
    ;;
  *)
    error "Estado inesperado do container na réplica: $R_STATUS"
    ;;
esac

info "Aguardando MySQL na réplica ficar disponível..."
for i in $(seq 1 40); do
  PING=$(ssh_run "$R_HOST" "$R_USER" \
    "docker exec ${R_DBC} mysqladmin ping -uroot -p${R_PASS} --silent 2>/dev/null \
      && echo pong || true")
  [[ "$PING" == *"pong"* ]] && break
  [[ $i -eq 40 ]] && error "MySQL na réplica não respondeu após 80s."
  sleep 2
done
success "MySQL na réplica respondendo."

info "Desativando read_only na réplica (se ativo)..."
ssh_run "$R_HOST" "$R_USER" \
  "docker exec ${R_DBC} mysql -uroot -p${R_PASS} \
    -e 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;' 2>/dev/null || true" \
  | while read -r l; do dim "$l"; done
success "read_only desativado."

# =============================================================================
#  FASE 4 — CONFIGURAR MASTER
# =============================================================================
step "FASE 4/11 — Configurando master"

info "Verificando container master '${M_DBC}'..."
M_CSTATUS=$(ssh_run "$M_HOST" "$M_USER" \
  "docker inspect ${M_DBC} --format='{{.State.Status}}' 2>/dev/null || echo absent")
[[ "$M_CSTATUS" != "running" ]] \
  && error "Container master '${M_DBC}' não está running (status: ${M_CSTATUS})."
success "Container master rodando."

LOG_BIN=$(ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'log_bin';\" 2>/dev/null | awk '{print \$2}'")
BINLOG_FMT=$(ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'binlog_format';\" 2>/dev/null | awk '{print \$2}'")
CURRENT_SID=$(ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'server_id';\" 2>/dev/null | awk '{print \$2}'")
CURRENT_RO=$(ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} --silent \
    -e \"SHOW VARIABLES LIKE 'read_only';\" 2>/dev/null | awk '{print \$2}'")

NEEDS_RESTART=false
[[ "$LOG_BIN"     != "ON"     ]] && { warn "Binary Log inativo — será ativado.";                  NEEDS_RESTART=true; }
[[ "$BINLOG_FMT"  != "ROW"    ]] && { warn "binlog_format=${BINLOG_FMT} — corrigindo para ROW.";  NEEDS_RESTART=true; }
[[ "$CURRENT_SID" != "$M_SID" ]] && { warn "server-id incorreto (${CURRENT_SID}) — corrigindo."; NEEDS_RESTART=true; }
[[ "$CURRENT_RO"  == "ON"     ]] && { warn "read_only=ON no master — desativando.";               NEEDS_RESTART=true; }

if $NEEDS_RESTART; then
  info "Escrevendo replication.cnf no master..."
  ssh_run "$M_HOST" "$M_USER" "
    docker exec ${M_DBC} bash -c \"cat > /etc/mysql/conf.d/replication.cnf <<EOF
[mysqld]
server-id        = ${M_SID}
log_bin          = mysql-bin
binlog_format    = ROW
expire_logs_days = 7
read_only        = OFF
super_read_only  = OFF
EOF\"" | while read -r l; do dim "$l"; done

  info "Reiniciando container master..."
  ssh_run "$M_HOST" "$M_USER" "docker restart ${M_DBC}" \
    | while read -r l; do dim "$l"; done

  info "Aguardando MySQL master reiniciar..."
  for i in $(seq 1 30); do
    PING=$(ssh_run "$M_HOST" "$M_USER" \
      "docker exec ${M_DBC} mysqladmin ping -uroot -p${M_PASS} --silent 2>/dev/null \
        && echo pong || true")
    [[ "$PING" == *"pong"* ]] && break
    [[ $i -eq 30 ]] && error "MySQL master não voltou após restart."
    sleep 2
  done
  success "Master reiniciado."
else
  success "Master já configurado corretamente."
fi

info "Configurando usuário de replicação '${REP_USER}'..."
EXISTS_USER=$(ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} --silent \
    -e \"SELECT User FROM mysql.user WHERE User='${REP_USER}' AND Host='%';\" 2>/dev/null")

if [[ -n "$EXISTS_USER" ]]; then
  warn "Usuário '${REP_USER}' já existe — atualizando senha."
  ssh_run "$M_HOST" "$M_USER" \
    "docker exec ${M_DBC} mysql -uroot -p${M_PASS} \
      -e \"ALTER USER '${REP_USER}'@'%'
        IDENTIFIED WITH mysql_native_password BY '${REP_PASS}';\" 2>/dev/null" \
    | while read -r l; do dim "$l"; done
else
  ssh_run "$M_HOST" "$M_USER" \
    "docker exec ${M_DBC} mysql -uroot -p${M_PASS} \
      -e \"CREATE USER '${REP_USER}'@'%'
        IDENTIFIED WITH mysql_native_password BY '${REP_PASS}';\" 2>/dev/null" \
    | while read -r l; do dim "$l"; done
fi

ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} \
    -e \"GRANT REPLICATION SLAVE ON *.* TO '${REP_USER}'@'%'; FLUSH PRIVILEGES;\" 2>/dev/null" \
  | while read -r l; do dim "$l"; done
success "Usuário '${REP_USER}' configurado."

# =============================================================================
#  FASE 5 — DUMP CONSISTENTE
# =============================================================================
step "FASE 5/11 — Gerando dump consistente"

DUMP_NAME="mysql-dump-${M_DB}-$(date +%Y%m%d%H%M%S).sql"
DUMP_REMOTE="${M_DUMPDIR}/${DUMP_NAME}"

info "Travando tabelas no master..."
ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} \
    -e 'FLUSH TABLES WITH READ LOCK;' 2>/dev/null" \
  | while read -r l; do dim "$l"; done

info "Capturando posição do binlog..."
MASTER_STATUS=$(ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} --silent \
    -e 'SHOW MASTER STATUS;' 2>/dev/null")
BINLOG_FILE=$(echo "$MASTER_STATUS" | awk '{print $1}')
BINLOG_POS=$(echo  "$MASTER_STATUS" | awk '{print $2}')

if [[ -z "$BINLOG_FILE" ]]; then
  ssh_run "$M_HOST" "$M_USER" \
    "docker exec ${M_DBC} mysql -uroot -p${M_PASS} \
      -e 'UNLOCK TABLES;' 2>/dev/null" \
    | while read -r l; do dim "$l"; done
  error "Não foi possível capturar posição do binlog."
fi

info "Binlog: ${BINLOG_FILE} @ posição ${BINLOG_POS}"
info "Gerando dump de '${M_DB}'..."

ssh_live "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysqldump \
    -uroot -p${M_PASS} \
    --single-transaction \
    --master-data=2 \
    --routines \
    --triggers \
    --events \
    ${M_DB} > ${DUMP_REMOTE} 2>/dev/null"

info "Liberando lock..."
ssh_run "$M_HOST" "$M_USER" \
  "docker exec ${M_DBC} mysql -uroot -p${M_PASS} \
    -e 'UNLOCK TABLES;' 2>/dev/null" \
  | while read -r l; do dim "$l"; done

DUMP_SIZE=$(ssh_run "$M_HOST" "$M_USER" "du -sh ${DUMP_REMOTE} | cut -f1")
success "Dump gerado: ${DUMP_REMOTE} (${DUMP_SIZE})"

# =============================================================================
#  FASE 6 — TRANSFERIR DUMP
# =============================================================================
step "FASE 6/11 — Transferindo dump para réplica"

TMP_DUMP="/tmp/${DUMP_NAME}"
R_DUMP_PATH="/home/${R_USER}/${DUMP_NAME}"

info "Baixando dump do master para o orquestrador..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "${M_USER}@${M_HOST}:${DUMP_REMOTE}" "$TMP_DUMP"

info "Enviando dump para a réplica..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "$TMP_DUMP" "${R_USER}@${R_HOST}:${R_DUMP_PATH}"

rm -f "$TMP_DUMP"
success "Dump transferido → ${R_HOST}:${R_DUMP_PATH}"

# =============================================================================
#  FASE 7 — IMPORTAR DUMP NA RÉPLICA
# =============================================================================
step "FASE 7/11 — Importando dump na réplica"

info "Garantindo banco '${R_DB}' na réplica..."
ssh_run "$R_HOST" "$R_USER" \
  "docker exec ${R_DBC} mysql -uroot -p${R_PASS} \
    -e \"CREATE DATABASE IF NOT EXISTS \\\`${R_DB}\\\`
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\" 2>/dev/null" \
  | while read -r l; do dim "$l"; done

info "Importando dump (${DUMP_SIZE}) — aguarde..."
ssh_live "$R_HOST" "$R_USER" \
  "docker exec -i ${R_DBC} mysql \
    -uroot -p${R_PASS} \
    --init-command='SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0;' \
    ${R_DB} < ${R_DUMP_PATH}"

success "Dump importado com sucesso."

# =============================================================================
#  FASE 8 — CONFIGURAR REPLICAÇÃO MySQL
# =============================================================================
step "FASE 8/11 — Configurando replicação MySQL"

info "Escrevendo replica.cnf..."
ssh_run "$R_HOST" "$R_USER" "
  docker exec ${R_DBC} bash -c \"cat > /etc/mysql/conf.d/replica.cnf <<EOF
[mysqld]
server-id              = ${R_SID}
relay_log              = relay-bin
log_bin                = mysql-bin
binlog_format          = ROW
read_only              = ON
super_read_only        = ON
expire_logs_days       = 7
EOF\"" | while read -r l; do dim "$l"; done

info "Reiniciando container da réplica..."
ssh_run "$R_HOST" "$R_USER" "docker restart ${R_DBC}" \
  | while read -r l; do dim "$l"; done

info "Aguardando MySQL da réplica reiniciar..."
for i in $(seq 1 40); do
  PING=$(ssh_run "$R_HOST" "$R_USER" \
    "docker exec ${R_DBC} mysqladmin ping -uroot -p${R_PASS} --silent 2>/dev/null \
      && echo pong || true")
  [[ "$PING" == *"pong"* ]] && break
  [[ $i -eq 40 ]] && error "MySQL da réplica não voltou após restart."
  sleep 2
done

info "Parando slave anterior (se existir)..."
ssh_run "$R_HOST" "$R_USER" \
  "docker exec ${R_DBC} mysql -uroot -p${R_PASS} \
    -e 'STOP SLAVE; RESET SLAVE ALL;' 2>/dev/null || true" \
  | while read -r l; do dim "$l"; done

info "Executando CHANGE MASTER TO..."
ssh_run "$R_HOST" "$R_USER" \
  "docker exec ${R_DBC} mysql -uroot -p${R_PASS} -e \"
    CHANGE MASTER TO
      MASTER_HOST     = '${M_HOST}',
      MASTER_PORT     = ${M_DBPORT},
      MASTER_USER     = '${REP_USER}',
      MASTER_PASSWORD = '${REP_PASS}',
      MASTER_LOG_FILE = '${BINLOG_FILE}',
      MASTER_LOG_POS  = ${BINLOG_POS};
  \" 2>/dev/null" | while read -r l; do dim "$l"; done

ssh_run "$R_HOST" "$R_USER" \
  "docker exec ${R_DBC} mysql -uroot -p${R_PASS} \
    -e 'START SLAVE;' 2>/dev/null" \
  | while read -r l; do dim "$l"; done

sleep 5

SLAVE_STATUS=$(ssh_run "$R_HOST" "$R_USER" \
  "docker exec ${R_DBC} mysql -uroot -p${R_PASS} -e 'SHOW SLAVE STATUS\G' 2>/dev/null")
IO_RUNNING=$(echo  "$SLAVE_STATUS" | grep "Slave_IO_Running:"      | awk '{print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:"     | awk '{print $2}')
LAST_ERROR=$(echo  "$SLAVE_STATUS" | grep "Last_Error:"            | sed 's/.*Last_Error: //')
SECONDS_BH=$(echo  "$SLAVE_STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')

[[ "$IO_RUNNING"  != "Yes" ]] && error "Slave_IO_Running=No.  Last_Error: ${LAST_ERROR}. Abortando."
[[ "$SQL_RUNNING" != "Yes" ]] && error "Slave_SQL_Running=No. Last_Error: ${LAST_ERROR}. Abortando."

success "Slave_IO_Running:      Yes"
success "Slave_SQL_Running:     Yes"
info    "Seconds_Behind_Master: ${SECONDS_BH:-0}"

# =============================================================================
#  FASE 9 — BUILD E SUBIDA DA API NA RÉPLICA
# =============================================================================
step "FASE 9/11 — Subindo API na réplica"

OLD_API=$(ssh_run "$R_HOST" "$R_USER" \
  "docker inspect ${R_APIC} --format='{{.State.Status}}' 2>/dev/null || echo absent")
if [[ "$OLD_API" != "absent" ]]; then
  warn "Container '${R_APIC}' já existe — removendo versão anterior..."
  ssh_run "$R_HOST" "$R_USER" "docker rm -f ${R_APIC} 2>/dev/null || true" \
    | while read -r l; do dim "$l"; done
fi

info "Clonando repositório da API na réplica..."
ssh_run "$R_HOST" "$R_USER" \
  "rm -rf ${REPO_DIR} && git clone ${API_REPO} 2>&1" \
  | while read -r l; do dim "$l"; done

info "Fazendo build da imagem '${API_IMAGE}' (pode demorar)..."
ssh_live "$R_HOST" "$R_USER" "cd ${REPO_DIR} && docker build -t ${API_IMAGE} ."

info "Iniciando container da API na réplica..."
ssh_run "$R_HOST" "$R_USER" \
  "docker run -d \
    --name ${R_APIC} \
    --restart unless-stopped \
    -p ${R_APIPORT}:8080 \
    -e DB_URL=jdbc:mysql://${R_HOST}:${R_DBPORT}/${API_DBNAME} \
    -e DB_USER=${API_DBUSER} \
    -e DB_PASSWORD=${API_DBPASS} \
    ${API_IMAGE}" | while read -r l; do dim "$l"; done

success "Container '${R_APIC}' iniciado."

# =============================================================================
#  FASE 10 — HEALTH-CHECK DA API NA RÉPLICA
# =============================================================================
step "FASE 10/11 — Health-check da API na réplica"

info "Aguardando API na réplica responder na porta ${R_APIPORT}..."
API_OK=false
for i in $(seq 1 24); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 \
    "http://${R_HOST}:${R_APIPORT}" 2>/dev/null || echo "000")
  if [[ "$HTTP" =~ ^[2345] ]]; then
    API_OK=true
    success "API respondendo (HTTP ${HTTP}) após $((i * 5))s."
    break
  fi
  dim "Tentativa $i/24 — HTTP ${HTTP} — aguardando 5s..."
  sleep 5
done

$API_OK || {
  warn "API não respondeu em 120s. Verifique os logs:"
  dim "  ssh -i ${SSH_KEY} ${R_USER}@${R_HOST} docker logs ${R_APIC}"
  echo ""
  read -rp "  Continuar e desativar a origem mesmo assim? (s/N): " FORCE
  [[ "$FORCE" =~ ^[sS]$ ]] || error "Abortado pelo usuário. Origem mantida intacta."
}

# =============================================================================
#  FASE 11 — DESATIVAR ORIGEM
# =============================================================================
step "FASE 11/11 — Desativando sistema na origem"

info "Parando e removendo API na origem ('${M_APIC}')..."
ssh_run "$M_HOST" "$M_USER" \
  "docker rm -f ${M_APIC} 2>/dev/null && echo removido || echo 'nao encontrado'" \
  | while read -r l; do dim "$l"; done
success "API '${M_APIC}' removida da origem."

info "Parando e removendo banco na origem ('${M_DBC}')..."
ssh_run "$M_HOST" "$M_USER" \
  "docker rm -f ${M_DBC} 2>/dev/null && echo removido || echo 'nao encontrado'" \
  | while read -r l; do dim "$l"; done
success "Banco '${M_DBC}' removido da origem."

# =============================================================================
#  RESUMO FINAL
# =============================================================================
SUMMARY_FILE="${SCRIPT_DIR}/migration-summary-$(date +%Y%m%d%H%M%S).txt"
cat > "$SUMMARY_FILE" <<EOF
=== Migração concluída — $(date) ===

ORIGEM (desativada)
  Host:            ${M_HOST}
  DB container:    ${M_DBC}  → REMOVIDO
  API container:   ${M_APIC} → REMOVIDO

DESTINO (ativo)
  Host:            ${R_HOST}
  DB container:    ${R_DBC}   (rodando, read_only=ON)
  API container:   ${R_APIC}  (rodando na porta ${R_APIPORT})
  API image:       ${API_IMAGE}
  DB URL:          jdbc:mysql://${R_HOST}:${R_DBPORT}/${API_DBNAME}

REPLICAÇÃO
  Binlog file:     ${BINLOG_FILE}
  Binlog posição:  ${BINLOG_POS}
  IO Running:      ${IO_RUNNING}
  SQL Running:     ${SQL_RUNNING}
  Lag (s):         ${SECONDS_BH:-0}

DUMP
  Gerado em:       ${M_HOST}:${DUMP_REMOTE}
  Importado em:    ${R_HOST}:${R_DUMP_PATH}
  Tamanho:         ${DUMP_SIZE}

CHAVE SSH
  Localização:     ${SSH_KEY}
  (mantenha esta chave para acessos futuros às VMs)

COMANDOS ÚTEIS
  # Logs da API no destino:
  ssh -i ${SSH_KEY} ${R_USER}@${R_HOST} "docker logs -f ${R_APIC}"

  # Status da replicação:
  ssh -i ${SSH_KEY} ${R_USER}@${R_HOST} \
    "docker exec ${R_DBC} mysql -uroot -p${R_PASS} -e 'SHOW SLAVE STATUS\G'"

  # Lag atual:
  ssh -i ${SSH_KEY} ${R_USER}@${R_HOST} \
    "docker exec ${R_DBC} mysql -uroot -p${R_PASS} -e 'SHOW SLAVE STATUS\G'" \
    | grep Seconds_Behind
EOF

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Migração concluída com sucesso!                        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
cat "$SUMMARY_FILE"
echo ""
success "Resumo salvo em: ${SUMMARY_FILE}"
echo ""