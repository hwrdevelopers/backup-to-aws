#!/usr/bin/env bash
# =============================================================================
# MySQL Backup to S3 — Desinstalador
# Remove componentes instalados pelo install.sh.
# Uso: sudo bash uninstall.sh
# =============================================================================
set -euo pipefail

readonly SERVICE_USER="backuptoaws"
readonly CONFIG_DIR="/etc/backup-to-aws"
readonly INSTALL_BIN="/usr/local/bin/backup-to-aws"
readonly CRON_FILE="/etc/cron.d/backup-to-aws"
readonly LOGROTATE_FILE="/etc/logrotate.d/backup-to-aws"
readonly LOG_FILE="/var/log/backup-to-aws.log"
readonly TEMP_DIR="/var/tmp/backup-to-aws"

# =============================================================================
# Helpers
# =============================================================================

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()   { error "$@"; exit 1; }

confirm() {
    local prompt="$1"
    read -rp "$prompt [s/N]: " answer
    [[ "${answer,,}" == "s" ]]
}

remove_if_exists() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        info "Removido: ${label} (${path})"
    fi
}

# =============================================================================
# Verificações
# =============================================================================

if [[ "$(id -u)" -ne 0 ]]; then
    die "Este script precisa ser executado como root (sudo bash uninstall.sh)"
fi

echo ""
echo "============================================================"
echo "  MySQL Backup to S3 — Desinstalação"
echo "============================================================"
echo ""

# =============================================================================
# Remove componentes principais (sempre)
# =============================================================================

info "Removendo componentes principais..."
remove_if_exists "$INSTALL_BIN" "Script"
remove_if_exists "$CRON_FILE" "Cron"
remove_if_exists "$LOGROTATE_FILE" "Logrotate"

# =============================================================================
# Remove configuração (pergunta)
# =============================================================================

echo ""
if [[ -d "$CONFIG_DIR" ]]; then
    if confirm "Remover configuração e credenciais (${CONFIG_DIR})?"; then
        rm -rf "$CONFIG_DIR"
        info "Removido: Configuração (${CONFIG_DIR})"
    else
        warn "Mantido: ${CONFIG_DIR}"
    fi
fi

# =============================================================================
# Remove dados locais (pergunta)
# =============================================================================

if [[ -d "$TEMP_DIR" ]]; then
    local_size="$(du -sh "$TEMP_DIR" 2>/dev/null | cut -f1)"
    if confirm "Remover backups locais (${TEMP_DIR}, ${local_size:-vazio})?"; then
        rm -rf "$TEMP_DIR"
        info "Removido: Dados locais (${TEMP_DIR})"
    else
        warn "Mantido: ${TEMP_DIR}"
    fi
fi

# =============================================================================
# Remove log (pergunta)
# =============================================================================

if [[ -f "$LOG_FILE" ]]; then
    if confirm "Remover arquivo de log (${LOG_FILE})?"; then
        rm -f "$LOG_FILE"
        info "Removido: Log (${LOG_FILE})"
    else
        warn "Mantido: ${LOG_FILE}"
    fi
fi

# =============================================================================
# Remove usuário de sistema (pergunta)
# =============================================================================

if id "$SERVICE_USER" &>/dev/null; then
    if confirm "Remover usuário de sistema (${SERVICE_USER})?"; then
        userdel "$SERVICE_USER" 2>/dev/null || true
        info "Removido: Usuário (${SERVICE_USER})"
    else
        warn "Mantido: ${SERVICE_USER}"
    fi
fi

# =============================================================================
# Resumo
# =============================================================================

echo ""
echo "============================================================"
info "Desinstalação concluída!"
echo ""
warn "Backups no S3 NÃO foram removidos."
echo "  Para removê-los manualmente:"
echo "    aws s3 rm s3://BUCKET/PREFIX/ --recursive"
echo "============================================================"
