#!/usr/bin/env bash
# =============================================================================
# MySQL Backup to S3 — Instalador
# Configura backup automatizado em um servidor Ubuntu.
# Uso: sudo bash install.sh
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVICE_USER="mysql-backup"
readonly CONFIG_DIR="/etc/mysql-backup"
readonly INSTALL_BIN="/usr/local/bin/mysql-backup"
readonly CRON_FILE="/etc/cron.d/mysql-backup"
readonly LOGROTATE_FILE="/etc/logrotate.d/mysql-backup"
readonly TEMP_DIR="/var/tmp/mysql-backup"
readonly LOG_FILE="/var/log/mysql-backup.log"

# =============================================================================
# Helpers
# =============================================================================

info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()   { error "$@"; exit 1; }

ask() {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " answer
        echo "${answer:-$default}"
    else
        read -rp "$prompt: " answer
        echo "$answer"
    fi
}

# =============================================================================
# Pré-requisitos
# =============================================================================

if [[ "$(id -u)" -ne 0 ]]; then
    die "Este script precisa ser executado como root (sudo bash install.sh)"
fi

info "Verificando pré-requisitos..."

# mysqldump
if ! command -v mysqldump &>/dev/null; then
    die "mysqldump não encontrado. Instale o MySQL/MariaDB client primeiro."
fi

# gzip
if ! command -v gzip &>/dev/null; then
    die "gzip não encontrado."
fi

# aws cli
if ! command -v aws &>/dev/null; then
    info "Instalando AWS CLI..."
    apt-get update -qq && apt-get install -y -qq awscli
fi

# mailutils (para notificações)
if ! command -v mail &>/dev/null; then
    info "Instalando mailutils..."
    apt-get update -qq && apt-get install -y -qq mailutils 2>/dev/null || \
        warn "Não foi possível instalar mailutils — notificações por email não funcionarão"
fi

info "Pré-requisitos OK"

# =============================================================================
# Usuário de sistema
# =============================================================================

if id "$SERVICE_USER" &>/dev/null; then
    info "Usuário ${SERVICE_USER} já existe"
else
    info "Criando usuário de sistema → ${SERVICE_USER}"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# =============================================================================
# Estrutura de diretórios
# =============================================================================

info "Criando diretórios..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$TEMP_DIR"

# =============================================================================
# Copia script principal
# =============================================================================

info "Instalando script → ${INSTALL_BIN}"
cp "$SCRIPT_DIR/backup.sh" "$INSTALL_BIN"
chown root:"$SERVICE_USER" "$INSTALL_BIN"
chmod 750 "$INSTALL_BIN"

# =============================================================================
# Configuração
# =============================================================================

if [[ -f "${CONFIG_DIR}/backup.conf" ]]; then
    warn "Configuração já existe: ${CONFIG_DIR}/backup.conf (não será sobrescrita)"
else
    info "Copiando configuração de exemplo → ${CONFIG_DIR}/backup.conf"
    cp "$SCRIPT_DIR/backup.conf.example" "${CONFIG_DIR}/backup.conf"
    info "Edite ${CONFIG_DIR}/backup.conf com suas configurações de S3/MySQL"
fi

# =============================================================================
# Credenciais MySQL
# =============================================================================

if [[ -f "${CONFIG_DIR}/.my.cnf" ]]; then
    warn "Credenciais MySQL já existem: ${CONFIG_DIR}/.my.cnf (não será sobrescrito)"
else
    echo ""
    info "Configurando credenciais MySQL para backup"
    echo ""

    MYSQL_USER="$(ask "  Usuário MySQL" "backup_user")"
    read -rsp "  Senha MySQL: " MYSQL_PASS
    echo ""

    (umask 077; cat > "${CONFIG_DIR}/.my.cnf" <<EOF
[client]
user=${MYSQL_USER}
password=${MYSQL_PASS}
EOF
    )
    unset MYSQL_PASS

    info "Credenciais salvas em ${CONFIG_DIR}/.my.cnf"
fi

# =============================================================================
# Permissões
# =============================================================================

chown -R "$SERVICE_USER":"$SERVICE_USER" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
chmod 600 "${CONFIG_DIR}/backup.conf" "${CONFIG_DIR}/.my.cnf"

chown "$SERVICE_USER":"$SERVICE_USER" "$TEMP_DIR"
chmod 700 "$TEMP_DIR"

touch "$LOG_FILE"
chown "$SERVICE_USER":"$SERVICE_USER" "$LOG_FILE"
chmod 640 "$LOG_FILE"

# =============================================================================
# Testa conexão MySQL
# =============================================================================

info "Testando conexão MySQL..."
# shellcheck source=/dev/null
source "${CONFIG_DIR}/backup.conf"

if sudo -u "$SERVICE_USER" mysql --defaults-extra-file="${CONFIG_DIR}/.my.cnf" \
         -h "${MYSQL_HOST:-localhost}" -P "${MYSQL_PORT:-3306}" \
         -e "SELECT 1" &>/dev/null; then
    info "Conexão MySQL OK"
else
    warn "Falha na conexão MySQL — verifique as credenciais em ${CONFIG_DIR}/.my.cnf"
    warn "O script foi instalado, mas o backup não funcionará até corrigir a conexão"
fi

# =============================================================================
# Testa acesso ao S3
# =============================================================================

info "Testando acesso ao S3..."
if sudo -u "$SERVICE_USER" aws s3 ls "s3://${S3_BUCKET:-}/" --region "${AWS_REGION:-us-east-1}" &>/dev/null 2>&1; then
    info "Acesso ao S3 OK"
else
    warn "Falha no acesso ao S3 — verifique as credenciais AWS e o bucket em ${CONFIG_DIR}/backup.conf"
fi

# =============================================================================
# Cron
# =============================================================================

info "Configurando cron (02:00 diário) → ${CRON_FILE}"
cat > "$CRON_FILE" <<EOF
# MySQL Backup to S3 — execução diária às 02:00
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 2 * * * ${SERVICE_USER} /usr/local/bin/mysql-backup >/dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"

# =============================================================================
# Logrotate
# =============================================================================

info "Configurando logrotate → ${LOGROTATE_FILE}"
cat > "$LOGROTATE_FILE" <<EOF
/var/log/mysql-backup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 ${SERVICE_USER} ${SERVICE_USER}
}
EOF

chmod 644 "$LOGROTATE_FILE"

# =============================================================================
# Resumo
# =============================================================================

echo ""
echo "============================================================"
info "Instalação concluída!"
echo "============================================================"
echo ""
echo "  Arquivos instalados:"
echo "    Usuário:     ${SERVICE_USER} (sistema)"
echo "    Script:      ${INSTALL_BIN}"
echo "    Config:      ${CONFIG_DIR}/backup.conf"
echo "    Credenciais: ${CONFIG_DIR}/.my.cnf"
echo "    Cron:        ${CRON_FILE} (02:00 diário)"
echo "    Logrotate:   ${LOGROTATE_FILE}"
echo "    Log:         ${LOG_FILE}"
echo "    Temp:        ${TEMP_DIR}/ (modo local)"
echo ""
echo "  Próximos passos:"
echo "    1. Edite ${CONFIG_DIR}/backup.conf (S3_BUCKET, DATABASES, etc.)"
echo "    2. Teste: sudo -u ${SERVICE_USER} mysql-backup"
echo "    3. Verifique no S3: aws s3 ls s3://BUCKET/PREFIX/"
echo "============================================================"
