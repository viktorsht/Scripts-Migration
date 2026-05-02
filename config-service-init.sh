#!/bin/bash
# =============================================================================
#  config-service-init.sh — Inicializa o ConfigService em um host
#  Uso: ./config-service-init.sh config_service_init.json
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
for cmd in ssh ssh-keygen ssh-copy-id scp jq curl; do
  command -v "$cmd" &>/dev/null \
    || error "Dependência não encontrada: '$cmd'"
done

# ── Argumento ──────────────────────────────────────────────────────────────────
CONFIG="${1:-}"
[[ -z "$CONFIG" ]]   && { echo "Uso: $0 <config_service_init.json>"; exit 1; }
[[ ! -f "$CONFIG" ]] && error "Arquivo não encontrado: $CONFIG"
jq empty "$CONFIG" 2>/dev/null || error "JSON inválido: $CONFIG"

jp() { jq -r "$1" "$CONFIG"; }

# ── Leitura do JSON ────────────────────────────────────────────────────────────
HOST=$(jp     '.host')
SSH_USER=$(jp '.ssh_user')

CS_CONTAINER=$(jp  '.container')
CS_PORT=$(jp       '.port')
CS_REPO=$(jp       '.repo')
CS_IMAGE=$(jp      '.image')
CS_CONFIG_DIR=$(jp '.config_dir')       # ex: /opt/config
CS_CONFIG_FILE="${CS_CONFIG_DIR}/services.json"

REPO_DIR=$(basename "$CS_REPO" .git)

# ── Chave SSH dedicada ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
SSH_KEY="${KEYS_DIR}/ssh_migration_key"

# ── SSH helpers ────────────────────────────────────────────────────────────────
ssh_cap() {
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "${SSH_USER}@${HOST}" "$@" 2>/dev/null \
    | grep -v "^Warning" | grep -v "^$" || true
}
ssh_run() {
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "${SSH_USER}@${HOST}" "$@" 2>/dev/null
}
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
echo -e "${BOLD}${CYAN}║         CONFIG SERVICE INITIALIZER           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Host:${NC}       ${SSH_USER}@${HOST}"
echo -e "  ${BOLD}Container:${NC}  ${CS_CONTAINER}"
echo -e "  ${BOLD}Porta:${NC}      ${CS_PORT}"
echo -e "  ${BOLD}Repo:${NC}       ${CS_REPO}"
echo -e "  ${BOLD}Config dir:${NC} ${CS_CONFIG_DIR}"
echo ""
warn "Se o container '${CS_CONTAINER}' já existir, será recriado."
echo ""
read -rp "  Confirma inicialização? (s/N): " CONFIRM
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
    -C "config-service-init-$(date +%Y%m%d)" \
    -N "" -q
  success "Chave gerada: ${SSH_KEY}"
fi

KEY_CHECK=$(ssh -i "$SSH_KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=5 \
  -o LogLevel=ERROR \
  "${SSH_USER}@${HOST}" "echo ok" 2>/dev/null || echo "fail")

if [[ "$KEY_CHECK" != "ok" ]]; then
  info "Instalando chave na VM (${SSH_USER}@${HOST})..."
  warn "Digite a senha SSH quando solicitado (apenas desta vez):"
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

ssh_run "docker ps > /dev/null" \
  || error "Docker não disponível em ${HOST}."
success "Docker OK."

# =============================================================================
#  FASE 2 — SERVICES.JSON
# =============================================================================
step "FASE 2/5 — Preparando services.json"

info "Criando diretório '${CS_CONFIG_DIR}' no host..."
ssh_run "sudo mkdir -p ${CS_CONFIG_DIR} && sudo chown ${SSH_USER}:${SSH_USER} ${CS_CONFIG_DIR}"

# Verifica se já existe um services.json no host
EXISTING=$(ssh_cap "test -f ${CS_CONFIG_FILE} && echo yes || echo no")

if [[ "$EXISTING" == "yes" ]]; then
  warn "Arquivo '${CS_CONFIG_FILE}' já existe no host."
  read -rp "  Sobrescrever com o do JSON de configuração? (s/N): " OVERWRITE
  if [[ ! "$OVERWRITE" =~ ^[sS]$ ]]; then
    success "Mantendo services.json existente no host."
    SKIP_UPLOAD=true
  else
    SKIP_UPLOAD=false
  fi
else
  SKIP_UPLOAD=false
fi

if [[ "$SKIP_UPLOAD" == "false" ]]; then
  # Extrai o bloco "services" do JSON de configuração e envia para o host
  SERVICES_JSON=$(jq -r '.services' "$CONFIG")
  if [[ "$SERVICES_JSON" == "null" || -z "$SERVICES_JSON" ]]; then
    warn "Nenhuma chave 'services' no JSON — criando services.json vazio."
    SERVICES_JSON="{}"
  fi

  TMP_SERVICES=$(mktemp)
  echo "$SERVICES_JSON" > "$TMP_SERVICES"

  scp -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      "$TMP_SERVICES" "${SSH_USER}@${HOST}:${CS_CONFIG_FILE}"

  rm -f "$TMP_SERVICES"
  success "services.json enviado para ${HOST}:${CS_CONFIG_FILE}"
  dim "Conteúdo:"
  echo "$SERVICES_JSON" | while read -r l; do dim "  $l"; done
fi

# =============================================================================
#  FASE 3 — BUILD DA IMAGEM
# =============================================================================
step "FASE 3/5 — Build da imagem"

info "Removendo container anterior (se existir)..."
ssh_run "docker rm -f ${CS_CONTAINER} 2>/dev/null || true"

info "Clonando repositório '${CS_REPO}'..."
ssh_run "rm -rf ${REPO_DIR} && git clone ${CS_REPO} 2>&1" \
  | while read -r l; do dim "$l"; done

info "Buildando imagem '${CS_IMAGE}' (pode demorar)..."
ssh_live "cd ${REPO_DIR} && docker build -t ${CS_IMAGE} ."

success "Imagem '${CS_IMAGE}' pronta."

# =============================================================================
#  FASE 4 — SUBIR O CONTAINER
# =============================================================================
step "FASE 4/5 — Subindo ConfigService"

info "Iniciando container '${CS_CONTAINER}'..."
ssh_run "
  docker run -d \
    --name ${CS_CONTAINER} \
    --restart unless-stopped \
    -p ${CS_PORT}:8080 \
    -v ${CS_CONFIG_DIR}:${CS_CONFIG_DIR} \
    -e CONFIG_FILE_PATH=${CS_CONFIG_FILE} \
    ${CS_IMAGE}
" | while read -r l; do dim "$l"; done

success "Container '${CS_CONTAINER}' iniciado."

# =============================================================================
#  FASE 5 — HEALTH CHECK
# =============================================================================
step "FASE 5/5 — Health check"

info "Aguardando ConfigService responder em http://${HOST}:${CS_PORT}/health ..."
CS_OK=false
for i in $(seq 1 24); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 3 \
    "http://${HOST}:${CS_PORT}/health" 2>/dev/null || echo "000")

  if [[ "$HTTP" == "200" ]]; then
    CS_OK=true
    success "ConfigService respondendo (HTTP ${HTTP}) após $((i * 5))s."
    break
  fi

  dim "Tentativa $i/24 — HTTP ${HTTP} — aguardando 5s..."
  sleep 5
done

if ! $CS_OK; then
  warn "ConfigService não respondeu em 120s."
  dim "  ssh -i ${SSH_KEY} ${SSH_USER}@${HOST} docker logs -f ${CS_CONTAINER}"
  exit 1
fi

# Exibe os serviços carregados
info "Serviços registrados:"
curl -s "http://${HOST}:${CS_PORT}/config" \
  | jq . 2>/dev/null \
  | while read -r l; do dim "  $l"; done

# =============================================================================
#  RESUMO
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║      ConfigService iniciado com sucesso!     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}URL base:${NC}   http://${HOST}:${CS_PORT}"
echo -e "  ${BOLD}Endpoints:${NC}"
dim "  GET  http://${HOST}:${CS_PORT}/config           → lista todos os serviços"
dim "  GET  http://${HOST}:${CS_PORT}/config/{nome}    → URL de um serviço"
dim "  POST http://${HOST}:${CS_PORT}/config/reload    → recarrega services.json"
dim "  GET  http://${HOST}:${CS_PORT}/health           → health check"
echo ""
echo -e "  ${BOLD}Logs:${NC}"
dim "  ssh -i ${SSH_KEY} ${SSH_USER}@${HOST} docker logs -f ${CS_CONTAINER}"
echo ""