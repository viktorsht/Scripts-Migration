#!/bin/bash
# =============================================================================
#  mysql-migrate.sh — Orquestrador de migração MySQL + API
#
#  Fluxo:
#    0.  Gera chave SSH dedicada e distribui para as duas VMs
#    1.  Valida SSH e Docker nas duas VMs
#    2.  Garante container MySQL no destino
#    3.  Dump do banco na origem
#    4.  Transfere dump para o destino
#    5.  Importa dump no destino
#    6.  Build e subida da API no destino
#    7.  Health-check da API no destino
#    8.  Para e remove API + banco na origem
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

O_HOST=$(jp    '.origin.host')
O_USER=$(jp    '.origin.ssh_user')
O_DBC=$(jp     '.origin.db_container')
O_APIC=$(jp    '.origin.api_container')
O_DBPORT=$(jp  '.origin.db_port')
O_PASS=$(jp    '.origin.root_password')
O_DB=$(jp      '.origin.db')
O_DUMPDIR=$(jp '.origin.dump_dir')

D_HOST=$(jp    '.destination.host')
D_USER=$(jp    '.destination.ssh_user')
D_DBC=$(jp     '.destination.db_container')
D_APIC=$(jp    '.destination.api_container')
D_DBPORT=$(jp  '.destination.db_port')
D_APIPORT=$(jp '.destination.api_port')
D_PASS=$(jp    '.destination.root_password')
D_DB=$(jp      '.destination.db')
D_IMAGE=$(jp   '.destination.mysql_image')

API_REPO=$(jp   '.api.repo')
API_IMAGE=$(jp  '.api.image')
API_DBUSER=$(jp '.api.db_user')
API_DBPASS=$(jp '.api.db_password')
API_DBNAME=$(jp '.api.db_name')

REPO_DIR=$(basename "$API_REPO" .git)

# ── Variáveis de estado ────────────────────────────────────────────────────────
DUMP_NAME=""
DUMP_REMOTE=""
DUMP_SIZE=""
D_DUMP_PATH=""

# ── Chave SSH dedicada ─────────────────────────────────────────────────────────
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
      -o LogLevel=ERROR \
      "${user}@${host}" "$@" 2>/dev/null
}
ssh_cap() {
  local host="$1" user="$2"; shift 2
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o PasswordAuthentication=no \
      -o LogLevel=ERROR \
      "${user}@${host}" "$@" 2>/dev/null \
      | grep -v "^Warning" | grep -v "^$" || true
}
ssh_live() {
  local host="$1" user="$2"; shift 2
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o PasswordAuthentication=no \
      -o LogLevel=ERROR \
      "${user}@${host}" "$@"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           MySQL + API Migration Orchestrator             ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Origem:${NC}   ${O_USER}@${O_HOST}  •  banco '${O_DBC}'  •  api '${O_APIC}'"
echo -e "  ${BOLD}Destino:${NC}  ${D_USER}@${D_HOST}  •  banco '${D_DBC}'  •  api '${D_APIC}'"
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
step "FASE 0/8 — Configurando chave SSH dedicada"

mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

if [[ -f "$SSH_KEY" ]]; then
  success "Chave já existe: ${SSH_KEY}"
else
  info "Gerando chave SSH dedicada..."
  ssh-keygen -t ed25519 \
    -f "$SSH_KEY" \
    -C "mysql-migration-$(date +%Y%m%d)" \
    -N "" -q
  success "Chave gerada: ${SSH_KEY}"
fi

dim "$(cat "${SSH_KEY}.pub")"
echo ""
warn "Você precisará digitar a senha SSH de cada VM UMA VEZ agora."
echo ""

info "Instalando chave na origem (${O_USER}@${O_HOST})..."
ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no "${O_USER}@${O_HOST}" \
  || error "Falha ao instalar chave na origem."
success "Chave instalada na origem."

info "Instalando chave no destino (${D_USER}@${D_HOST})..."
ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no "${D_USER}@${D_HOST}" \
  || error "Falha ao instalar chave no destino."
success "Chave instalada no destino."

# =============================================================================
#  FASE 1 — CONECTIVIDADE SSH E DOCKER
# =============================================================================
step "FASE 1/8 — Verificando SSH e Docker"

for role in origem destino; do
  [[ "$role" == "origem"  ]] && h=$O_HOST u=$O_USER || h=$D_HOST u=$D_USER
  info "SSH $role ($h)..."
  ssh_run "$h" "$u" "echo ok" | grep -q "ok" \
    || error "SSH na $role falhou."
  info "Docker $role ($h)..."
  ssh_run "$h" "$u" "docker info > /dev/null && echo ok" | grep -q "ok" \
    || error "Docker não disponível na $role ($h)."
  success "$role OK."
done

# =============================================================================
#  FASE 2 — GARANTIR CONTAINER MYSQL NO DESTINO
# =============================================================================
# step "FASE 2/8 — Container MySQL no destino"

# D_STATUS=$(ssh_cap "$D_HOST" "$D_USER" \
#   "docker inspect ${D_DBC} --format='{{.State.Status}}' 2>/dev/null || echo absent")

# case "$D_STATUS" in
#   running)
#     success "Container '${D_DBC}' já está rodando."
#     ;;
#   absent|"")
#     info "Criando container '${D_DBC}' com imagem '${D_IMAGE}'..."
#     ssh_run "$D_HOST" "$D_USER" \
#       "docker run -d \
#         --name ${D_DBC} \
#         --restart unless-stopped \
#         -e MYSQL_ROOT_PASSWORD=${D_PASS} \
#         -e MYSQL_DATABASE=${D_DB} \
#         -p ${D_DBPORT}:3306 \
#         -v ${D_DBC}_data:/var/lib/mysql \
#         ${D_IMAGE}" | while read -r l; do dim "$l"; done
#     success "Container '${D_DBC}' criado."
#     ;;
#   exited|stopped|created)
#     info "Container '${D_DBC}' está '${D_STATUS}' — iniciando..."
#     ssh_run "$D_HOST" "$D_USER" "docker start ${D_DBC}" \
#       | while read -r l; do dim "$l"; done
#     ;;
#   *)
#     error "Estado inesperado do container no destino: '${D_STATUS}'"
#     ;;
# esac


step "FASE 2/8 — Container MySQL no destino"

D_STATUS=$(ssh_cap "$D_HOST" "$D_USER" \
  "docker inspect ${D_DBC} --format='{{.State.Status}}' 2>/dev/null || echo absent")

case "$D_STATUS" in
  running)
    success "Container '${D_DBC}' já está rodando."
    ;;
  absent|"")
    info "Removendo volume antigo (se existir)..."
    ssh_run "$D_HOST" "$D_USER" "docker volume rm ${D_DBC}_data 2>/dev/null || true"
    
    info "Criando volume novo para dados MySQL..."
    ssh_run "$D_HOST" "$D_USER" "docker volume create ${D_DBC}_data"
    
    info "Criando container '${D_DBC}' com imagem '${D_IMAGE}'..."
    ssh_run "$D_HOST" "$D_USER" \
      "docker run -d \
        --name ${D_DBC} \
        --restart unless-stopped \
        -e MYSQL_ROOT_PASSWORD=${D_PASS} \
        -e MYSQL_DATABASE=${D_DB} \
        -v ${D_DBC}_data:/var/lib/mysql \
        -p ${D_DBPORT}:3306 \
        ${D_IMAGE}" | while read -r l; do dim "$l"; done
    success "Container '${D_DBC}' criado."
    ;;
  exited|stopped|created)
    info "Container '${D_DBC}' está '${D_STATUS}' — iniciando..."
    ssh_run "$D_HOST" "$D_USER" "docker start ${D_DBC}" \
      | while read -r l; do dim "$l"; done
    ;;
  *)
    error "Estado inesperado do container no destino: '${D_STATUS}'"
esac

info "Aguardando MySQL no destino ficar disponível..."
for i in $(seq 1 40); do
  PING=$(ssh_cap "$D_HOST" "$D_USER" \
    "docker exec ${D_DBC} mysqladmin ping -uroot -p${D_PASS} --silent 2>/dev/null \
      && echo pong || true")
  [[ "$PING" == *"pong"* ]] && break
  [[ $i -eq 40 ]] && error "MySQL no destino não respondeu após 80s."
  sleep 2
done
success "MySQL no destino respondendo."

info "Desativando read_only no destino (se ativo)..."
ssh_run "$D_HOST" "$D_USER" \
  "docker exec ${D_DBC} mysql -uroot -p${D_PASS} \
    -e 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;' 2>/dev/null || true"

# =============================================================================
#  FASE 3 — DUMP DO BANCO NA ORIGEM
# =============================================================================
step "FASE 3/8 — Gerando dump na origem"

info "Verificando container MySQL na origem..."
O_STATUS=$(ssh_cap "$O_HOST" "$O_USER" \
  "docker inspect ${O_DBC} --format='{{.State.Status}}' 2>/dev/null || echo absent")
[[ "$O_STATUS" != "running" ]] \
  && error "Container '${O_DBC}' na origem não está running (status: ${O_STATUS})."
success "Container origem rodando."

DUMP_NAME="mysql-dump-${O_DB}-$(date +%Y%m%d%H%M%S).sql"
DUMP_REMOTE="${O_DUMPDIR}/${DUMP_NAME}"

info "Gerando dump de '${O_DB}'..."
ssh_live "$O_HOST" "$O_USER" \
  "docker exec ${O_DBC} mysqldump \
    -uroot -p${O_PASS} \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    ${O_DB} > ${DUMP_REMOTE} 2>/dev/null"

DUMP_SIZE=$(ssh_cap "$O_HOST" "$O_USER" "du -sh ${DUMP_REMOTE} | cut -f1")
success "Dump gerado: ${DUMP_REMOTE} (${DUMP_SIZE})"

# =============================================================================
#  FASE 4 — TRANSFERIR DUMP
# =============================================================================
step "FASE 4/8 — Transferindo dump para o destino"

TMP_DUMP="/tmp/${DUMP_NAME}"
D_DUMP_PATH="/home/${D_USER}/${DUMP_NAME}"

info "Baixando dump da origem..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "${O_USER}@${O_HOST}:${DUMP_REMOTE}" "$TMP_DUMP"

info "Enviando dump para o destino..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "$TMP_DUMP" "${D_USER}@${D_HOST}:${D_DUMP_PATH}"

rm -f "$TMP_DUMP"
success "Dump transferido → ${D_HOST}:${D_DUMP_PATH}"

# =============================================================================
#  FASE 5 — IMPORTAR DUMP NO DESTINO
# =============================================================================
step "FASE 5/8 — Importando dump no destino"

info "Garantindo banco '${D_DB}' no destino..."
ssh_run "$D_HOST" "$D_USER" \
  "docker exec ${D_DBC} mysql -uroot -p${D_PASS} \
    -e \"CREATE DATABASE IF NOT EXISTS \\\`${D_DB}\\\`
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\" 2>/dev/null"

info "Importando dump (${DUMP_SIZE}) — aguarde..."
ssh_live "$D_HOST" "$D_USER" \
  "docker exec -i ${D_DBC} mysql \
    -uroot -p${D_PASS} \
    --init-command='SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0;' \
    ${D_DB} < ${D_DUMP_PATH}"

success "Dump importado com sucesso."

# =============================================================================
#  FASE 6 — BUILD E SUBIDA DA API NO DESTINO
# =============================================================================
step "FASE 6/8 — Subindo API no destino"

OLD_API=$(ssh_cap "$D_HOST" "$D_USER" \
  "docker inspect ${D_APIC} --format='{{.State.Status}}' 2>/dev/null || echo absent")
if [[ "$OLD_API" != "absent" ]]; then
  warn "Container '${D_APIC}' já existe — removendo..."
  ssh_run "$D_HOST" "$D_USER" "docker rm -f ${D_APIC} 2>/dev/null || true"
fi

info "Clonando repositório '${API_REPO}'..."
ssh_run "$D_HOST" "$D_USER" \
  "rm -rf ${REPO_DIR} && git clone ${API_REPO} 2>&1" \
  | while read -r l; do dim "$l"; done

info "Buildando imagem '${API_IMAGE}' (pode demorar)..."
ssh_live "$D_HOST" "$D_USER" "cd ${REPO_DIR} && docker build -t ${API_IMAGE} ."

info "Iniciando container da API..."
ssh_run "$D_HOST" "$D_USER" \
  "docker run -d \
    --name ${D_APIC} \
    --restart unless-stopped \
    -p ${D_APIPORT}:8080 \
    -e DB_URL=jdbc:mysql://${D_HOST}:${D_DBPORT}/${API_DBNAME} \
    -e DB_USER=${API_DBUSER} \
    -e DB_PASSWORD=${API_DBPASS} \
    ${API_IMAGE}" | while read -r l; do dim "$l"; done

success "Container '${D_APIC}' iniciado."

# =============================================================================
#  FASE 7 — HEALTH-CHECK DA API NO DESTINO
# =============================================================================
step "FASE 7/8 — Health-check da API no destino"

info "Aguardando API responder em http://${D_HOST}:${D_APIPORT} ..."
API_OK=false
for i in $(seq 1 24); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 \
    "http://${D_HOST}:${D_APIPORT}" 2>/dev/null || echo "000")
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
  dim "  ssh -i ${SSH_KEY} ${D_USER}@${D_HOST} docker logs ${D_APIC}"
  echo ""
  read -rp "  Continuar e desativar a origem mesmo assim? (s/N): " FORCE
  [[ "$FORCE" =~ ^[sS]$ ]] || error "Abortado. Origem mantida intacta."
}

# =============================================================================
#  FASE 7.5 — ATUALIZAR CONFIGSERVICE
# =============================================================================
# step "FASE 7.5/8 — Atualizando ConfigService"

# CONFIG_SERVICE_URL=$(jp '.config_service.url')  # ex: "http://192.168.18.159:8080"
# SERVICE_NAME=$(jp       '.config_service.service_name')  # ex: "users"

# if [[ -n "$CONFIG_SERVICE_URL" && "$CONFIG_SERVICE_URL" != "null" ]]; then

#   info "Atualizando IP do serviço '${SERVICE_NAME}' no ConfigService..."

#   # Substitui o IP antigo pelo novo no services.json
#   CONFIG_FILE=$(jp '.config_service.config_file')  # ex: "/opt/config/services.json"
#   CONFIG_HOST=$(jp '.config_service.host')
#   CONFIG_USER=$(jp '.config_service.ssh_user')

#   ssh_run "$CONFIG_HOST" "$CONFIG_USER" \
#     "sed -i 's|${O_HOST}|${D_HOST}|g' ${CONFIG_FILE}"

#   # Dispara o reload
#   HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
#     -X POST "${CONFIG_SERVICE_URL}/config/reload" 2>/dev/null || echo "000")

#   if [[ "$HTTP" == "200" ]]; then
#     success "ConfigService atualizado (HTTP ${HTTP})."
#   else
#     warn "ConfigService retornou HTTP ${HTTP}. Verifique manualmente."
#   fi

# else
#   warn "config_service não definido no JSON — pulando atualização."
# fi


# =============================================================================
#  FASE 7.5 — ATUALIZAR CONFIGSERVICE
# =============================================================================
# step "FASE 7.5/8 — Atualizando ConfigService"

# CONFIG_SERVICE_URL=$(jp '.config_service.url')        # http://192.168.18.159:8080
# SERVICE_NAME=$(jp      '.config_service.service_name') # users
# CONFIG_FILE=$(jp       '.config_service.config_file')  # /home/cloud1/config/services.json
# CONFIG_HOST=$(jp       '.config_service.host')         # 192.168.18.159
# CONFIG_USER=$(jp       '.config_service.ssh_user')     # cloud1

# D_HOST=$(jp '.destination.host')   # 192.168.18.165
# D_PORT=$(jp '.destination.api_port') # 8080

# if [[ -z "$CONFIG_SERVICE_URL" || "$CONFIG_SERVICE_URL" == "null" ]]; then
#   warn "config_service não definido no JSON — pulando atualização."
# else
#   info "Atualizando '${SERVICE_NAME}' → http://${D_HOST}:${D_PORT} no ConfigService..."

#   # Atualiza o valor da chave corretamente via jq (mais seguro que sed)
#   ssh_run -i "$SSH_KEY" \
#       -o StrictHostKeyChecking=no \
#       -o LogLevel=ERROR \
#       "${CONFIG_USER}@${CONFIG_HOST}" \
#     "jq '.\"${SERVICE_NAME}\" = \"http://${D_HOST}:${D_PORT}\"' ${CONFIG_FILE} \
#         > /tmp/services_tmp.json \
#       && mv /tmp/services_tmp.json ${CONFIG_FILE}"

#   # Dispara o reload
#   HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
#     -X POST "${CONFIG_SERVICE_URL}/config/reload" 2>/dev/null || echo "000")

#   if [[ "$HTTP" == "200" ]]; then
#     success "ConfigService atualizado: '${SERVICE_NAME}' → http://${D_HOST}:${D_PORT}"
#   else
#     warn "ConfigService retornou HTTP ${HTTP}. Verifique manualmente."
#   fi
# fi


# =============================================================================
#  FASE 7.5 — ATUALIZAR CONFIGSERVICE
# =============================================================================
step "FASE 7.5/8 — Atualizando ConfigService"

CONFIG_SERVICE_URL=$(jp '.config_service.url')
SERVICE_NAME=$(jp      '.config_service.service_name')
CONFIG_FILE=$(jp       '.config_service.config_file')
CONFIG_HOST=$(jp       '.config_service.host')
CONFIG_USER=$(jp       '.config_service.ssh_user')

if [[ -z "$CONFIG_SERVICE_URL" || "$CONFIG_SERVICE_URL" == "null" ]]; then
  warn "config_service não definido no JSON — pulando atualização."
else
  info "Atualizando '${SERVICE_NAME}' → http://${D_HOST}:${D_APIPORT} no ConfigService..."

  # ssh_run "$CONFIG_HOST" "$CONFIG_USER" \
  #   "jq '.\"${SERVICE_NAME}\" = \"http://${D_HOST}:${D_APIPORT}\"' ${CONFIG_FILE} \
  #       > /tmp/services_tmp.json \
  #     && mv /tmp/services_tmp.json ${CONFIG_FILE}"
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      "${CONFIG_USER}@${CONFIG_HOST}" \
    "jq '.\"${SERVICE_NAME}\" = \"http://${D_HOST}:${D_APIPORT}\"' ${CONFIG_FILE} \
        > /tmp/services_tmp.json \
      && mv /tmp/services_tmp.json ${CONFIG_FILE}"

  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${CONFIG_SERVICE_URL}/config/reload" 2>/dev/null || echo "000")

  if [[ "$HTTP" == "200" ]]; then
    success "ConfigService atualizado: '${SERVICE_NAME}' → http://${D_HOST}:${D_APIPORT}"
  else
    warn "ConfigService retornou HTTP ${HTTP}. Verifique manualmente."
  fi
fi

# =============================================================================
#  FASE 8 — DESATIVAR ORIGEM
# =============================================================================
step "FASE 8/8 — Desativando sistema na origem"

info "Removendo API na origem ('${O_APIC}')..."
ssh_run "$O_HOST" "$O_USER" \
  "docker rm -f ${O_APIC} 2>/dev/null && echo removido || echo 'nao encontrado'" \
  | while read -r l; do dim "$l"; done
success "API '${O_APIC}' removida da origem."

info "Removendo banco na origem ('${O_DBC}')..."
ssh_run "$O_HOST" "$O_USER" \
  "docker rm -f ${O_DBC} 2>/dev/null && echo removido || echo 'nao encontrado'" \
  | while read -r l; do dim "$l"; done
success "Banco '${O_DBC}' removido da origem."

# =============================================================================
#  RESUMO FINAL
# =============================================================================
SUMMARY_FILE="${SCRIPT_DIR}/migration-summary-$(date +%Y%m%d%H%M%S).txt"
cat > "$SUMMARY_FILE" <<EOF
=== Migração concluída — $(date) ===

ORIGEM (desativada)
  Host:          ${O_HOST}
  DB container:  ${O_DBC}  → REMOVIDO
  API container: ${O_APIC} → REMOVIDO

DESTINO (ativo)
  Host:          ${D_HOST}
  DB container:  ${D_DBC}  (rodando)
  API container: ${D_APIC} (porta ${D_APIPORT})
  API image:     ${API_IMAGE}
  DB URL:        jdbc:mysql://${D_HOST}:${D_DBPORT}/${API_DBNAME}

DUMP
  Gerado em:     ${O_HOST}:${DUMP_REMOTE}
  Importado em:  ${D_HOST}:${D_DUMP_PATH}
  Tamanho:       ${DUMP_SIZE}

CHAVE SSH
  Localização:   ${SSH_KEY}
  (mantenha esta chave para acessos futuros às VMs)

COMANDOS ÚTEIS
  # Logs da API:
  ssh -i ${SSH_KEY} ${D_USER}@${D_HOST} "docker logs -f ${D_APIC}"

  # Acessar banco:
  ssh -i ${SSH_KEY} ${D_USER}@${D_HOST} \
    "docker exec -it ${D_DBC} mysql -uroot -p${D_PASS} ${D_DB}"
EOF

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         Migração concluída com sucesso!                  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
cat "$SUMMARY_FILE"
echo ""
success "Resumo salvo em: ${SUMMARY_FILE}"
echo ""