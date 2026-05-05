#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  service-init.sh — Primeiro start limpo de banco + API
#  Uso: ./service-init.sh service_initializer.json
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }
dim()     { echo -e "${DIM}    $*${NC}"; }

# ── Dependências ───────────────────────────────────────────────────────────────
for cmd in ssh ssh-keygen ssh-copy-id jq curl; do
  command -v "$cmd" &>/dev/null \
    || error "Dependência não encontrada: '$cmd'"
done

# ── Config ─────────────────────────────────────────────────────────────────────
CONFIG="${1:-}"
[[ -z "$CONFIG" ]]   && { echo "Uso: $0 <service_initializer.json>"; exit 1; }
[[ ! -f "$CONFIG" ]] && error "Arquivo não encontrado: $CONFIG"
jq empty "$CONFIG" 2>/dev/null || error "JSON inválido"

jp() { jq -r "$1" "$CONFIG"; }

HOST=$(jp '.host')
SSH_USER=$(jp '.ssh_user')

DB_CONTAINER=$(jp '.db.container')
DB_PORT=$(jp     '.db.port')
DB_ROOT_PASS=$(jp '.db.root_password')
DB_NAME=$(jp     '.db.name')
DB_IMAGE=$(jp    '.db.image')

API_CONTAINER=$(jp '.api.container')
API_PORT=$(jp      '.api.port')
API_REPO=$(jp      '.api.repo')
API_IMAGE=$(jp     '.api.image')
API_DB_USER=$(jp   '.api.db_user')
API_DB_PASS=$(jp   '.api.db_password')
API_DB_NAME=$(jp   '.api.db_name')

REPO_DIR=$(basename "$API_REPO" .git)

# ── Chave SSH dedicada ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
SSH_KEY="${KEYS_DIR}/ssh_migration_key"

# ── SSH helpers ────────────────────────────────────────────────────────────────
# ssh_cap → captura saída limpa para variável
ssh_cap() {
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "${SSH_USER}@${HOST}" "$@" 2>/dev/null | grep -v "^Warning" | grep -v "^$" || true
}
# ssh_run → executa e exibe saída (não captura)
ssh_run() {
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "${SSH_USER}@${HOST}" "$@" 2>/dev/null
}
# ssh_live → saída em tempo real (builds longos)
ssh_live() {
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "${SSH_USER}@${HOST}" "$@"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           SERVICE INITIALIZER                ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Host:${NC}  ${SSH_USER}@${HOST}"
echo -e "  ${BOLD}Banco:${NC} ${DB_CONTAINER} (${DB_IMAGE})"
echo -e "  ${BOLD}API:${NC}   ${API_CONTAINER} → ${API_REPO}"
echo ""
warn "Este script derruba e recria banco e API do zero."
echo ""
read -rp "  Confirma inicialização limpa? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# =============================================================================
#  FASE 0 — CHAVE SSH
# =============================================================================
step "FASE 0/5 — Chave SSH"

mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

if [[ -f "$SSH_KEY" ]]; then
  success "Chave já existe: ${SSH_KEY}"
else
  info "Gerando chave SSH dedicada..."
  ssh-keygen -t ed25519 \
    -f "$SSH_KEY" \
    -C "service-init-$(date +%Y%m%d)" \
    -N "" -q
  success "Chave gerada."
fi

# Verifica se a chave já está instalada na VM
KEY_CHECK=$(ssh -i "$SSH_KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=5 \
  -o LogLevel=ERROR \
  "${SSH_USER}@${HOST}" "echo ok" 2>/dev/null || echo "fail")

if [[ "$KEY_CHECK" != "ok" ]]; then
  info "Instalando chave na VM (${SSH_USER}@${HOST})..."
  warn "Digite a senha SSH da VM quando solicitado (apenas desta vez):"
  ssh-copy-id -i "${SSH_KEY}.pub" \
    -o StrictHostKeyChecking=no \
    "${SSH_USER}@${HOST}" \
    || error "Falha ao instalar chave. Verifique usuário e host."
  success "Chave instalada."
else
  success "Chave já aceita pela VM."
fi

# =============================================================================
#  FASE 1 — DOCKER
# =============================================================================
step "FASE 1/5 — Verificando Docker"

ssh_cap "docker ps > /dev/null" | grep -q "" || \
  ssh_run "docker ps > /dev/null" || \
  error "Docker não disponível em ${HOST}."

success "Docker OK."

# =============================================================================
#  FASE 2 — MYSQL LIMPO
# =============================================================================
step "FASE 2/5 — Subindo MySQL (limpo)"

info "Removendo container e volume antigos (se existirem)..."
ssh_run "docker rm -f ${DB_CONTAINER} 2>/dev/null || true"
ssh_run "docker volume rm ${DB_CONTAINER}_data 2>/dev/null || true"

info "Subindo MySQL (${DB_IMAGE})..."
ssh_run "
  docker run -d \
    --name ${DB_CONTAINER} \
    --restart unless-stopped \
    -e MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS} \
    -e MYSQL_DATABASE=${DB_NAME} \
    -p ${DB_PORT}:3306 \
    -v ${DB_CONTAINER}_data:/var/lib/mysql \
    ${DB_IMAGE}
" | while read -r l; do dim "$l"; done

success "Container '${DB_CONTAINER}' criado."

# =============================================================================
#  FASE 3 — AGUARDAR MYSQL
# =============================================================================
step "FASE 3/5 — Aguardando MySQL ficar pronto"

MYSQL_OK=false
for i in $(seq 1 30); do
  PING=$(ssh_cap \
    "docker exec ${DB_CONTAINER} mysqladmin ping -uroot -p${DB_ROOT_PASS} --silent 2>/dev/null \
      && echo pong || true")
  if [[ "$PING" == *"pong"* ]]; then
    MYSQL_OK=true
    success "MySQL pronto após $((i * 3))s."
    break
  fi
  dim "Aguardando MySQL... ($i/30)"
  sleep 3
done

$MYSQL_OK || error "MySQL não respondeu em 90s. Verifique os logs: ssh ${SSH_USER}@${HOST} docker logs ${DB_CONTAINER}"

# =============================================================================
#  FASE 4 — API LIMPA
# =============================================================================
step "FASE 4/5 — Subindo API (limpo)"

info "Removendo containers antigos da API..."
ssh_run "docker rm -f ${API_CONTAINER} 2>/dev/null || true"
ssh_run "docker rm -f \$(docker ps -aq --filter ancestor=${API_IMAGE}) 2>/dev/null || true"

info "Clonando repositório '${API_REPO}'..."
ssh_run "rm -rf ${REPO_DIR} && git clone ${API_REPO} 2>&1" \
  | while read -r l; do dim "$l"; done

info "Buildando imagem '${API_IMAGE}' (pode demorar)..."
ssh_live "cd ${REPO_DIR} && docker build -t ${API_IMAGE} ."

info "Iniciando container da API..."
ssh_run "
  docker run -d \
    --name ${API_CONTAINER} \
    --restart unless-stopped \
    -p ${API_PORT}:8080 \
    -e DB_URL=jdbc:mysql://${HOST}:${DB_PORT}/${API_DB_NAME} \
    -e DB_USER=${API_DB_USER} \
    -e DB_PASSWORD=${API_DB_PASS} \
    ${API_IMAGE}
" | while read -r l; do dim "$l"; done

success "Container '${API_CONTAINER}' iniciado."

# =============================================================================
#  FASE 5 — HEALTH CHECK
# =============================================================================
step "FASE 5/5 — Health check da API"

info "Aguardando API responder em http://${HOST}:${API_PORT} ..."
API_OK=false
for i in $(seq 1 12); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 \
    "http://${HOST}:${API_PORT}" 2>/dev/null || echo "000")

  if [[ "$HTTP" =~ ^[2345] ]]; then
    API_OK=true
    success "API respondendo (HTTP ${HTTP}) após $((i * 5))s."
    break
  fi

  dim "Tentativa $i/24 — HTTP ${HTTP} — aguardando 5s..."
  sleep 5
done

if ! $API_OK; then
  warn "API não respondeu em 120s."
  warn "Verifique os logs com:"
  dim "  ssh -i ${SSH_KEY} ${SSH_USER}@${HOST} docker logs -f ${API_CONTAINER}"
  exit 1
fi

# =============================================================================
#  FASE 6 — REGISTRAR NO CONFIGSERVICE (opcional)
# =============================================================================
step "FASE 6/6 — Registrando no ConfigService"

CS_URL=$(jp '.config_service.url   // empty')
CS_FILE=$(jp '.config_service.config_file // empty')
CS_HOST=$(jp '.config_service.host // empty')
CS_USER=$(jp '.config_service.ssh_user // empty')
CS_NAME=$(jp '.config_service.service_name // empty')

if [[ -z "$CS_URL" ]]; then
  warn "config_service não definido no JSON — pulando registro."
else
  info "Registrando '${CS_NAME}' → http://${HOST}:${API_PORT} no ConfigService..."

  # Atualiza o services.json na máquina do ConfigService
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      "${CS_USER}@${CS_HOST}" \
    "jq '.\"${CS_NAME}\" = \"http://${HOST}:${API_PORT}\"' ${CS_FILE} \
        > /tmp/services_tmp.json \
      && mv /tmp/services_tmp.json ${CS_FILE}"

  # Dispara o reload
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${CS_URL}/config/reload" 2>/dev/null || echo "000")

  if [[ "$HTTP" == "200" ]]; then
    success "Serviço '${CS_NAME}' registrado e ConfigService recarregado."
  else
    warn "ConfigService retornou HTTP ${HTTP}. Verifique manualmente."
  fi
fi

# =============================================================================
#  FINAL
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Ambiente inicializado com sucesso!         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Banco:${NC}  ${SSH_USER}@${HOST}:${DB_PORT} → ${DB_NAME}"
echo -e "  ${BOLD}API:${NC}    http://${HOST}:${API_PORT}"
echo ""
info "Logs da API:"
dim "  ssh -i ${SSH_KEY} ${SSH_USER}@${HOST} 'docker logs -f ${API_CONTAINER}'"
echo ""