#!/usr/bin/env bash
# =============================================================================
# MySQL Backup to S3
# Faz dump de bancos MySQL, comprime com gzip e envia para S3.
# Suporta streaming direto (sem disco) ou modo local (salva antes de enviar).
# =============================================================================
set -euo pipefail

readonly SCRIPT_NAME="backuptoaws"
readonly LOCK_FILE="/var/tmp/backup-to-aws/${SCRIPT_NAME}.lock"
readonly CONFIG_FILE="${MYSQL_BACKUP_CONF:-/etc/backup-to-aws/backup.conf}"
readonly MYCNF_FILE="/etc/backup-to-aws/.my.cnf"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_DBS=""

# =============================================================================
# Funções auxiliares
# =============================================================================

log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "$msg" | tee -a "${LOG_FILE:-/var/log/backup-to-aws.log}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

die() {
    log_error "$@"
    exit 1
}

send_notification() {
    if [[ -z "${NOTIFICATION_EMAIL:-}" ]]; then
        return
    fi

    local subject="[backuptoaws] FALHA em $(hostname) — ${FAIL_COUNT} banco(s)"
    local body
    body="Backup MySQL finalizado com falhas em $(hostname).

Timestamp: ${TIMESTAMP}
Sucessos:  ${SUCCESS_COUNT}
Falhas:    ${FAIL_COUNT}

Bancos com falha:
${FAILED_DBS}

Verifique o log: ${LOG_FILE}"

    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$NOTIFICATION_EMAIL" 2>/dev/null || \
            log_warn "Falha ao enviar email de notificação"
    else
        log_warn "Comando 'mail' não encontrado — notificação por email não enviada"
    fi
}

cleanup_local() {
    if [[ "$UPLOAD_MODE" != "local" ]]; then
        return
    fi

    log_info "Limpando backups locais com mais de ${LOCAL_RETENTION_DAYS} dias"
    find "$TEMP_DIR" -maxdepth 1 -name "*_[0-9]*_[0-9]*.sql.gz" -type f -mtime +"$LOCAL_RETENTION_DAYS" -delete 2>/dev/null || true
}

# =============================================================================
# Carrega configuração
# =============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Arquivo de configuração não encontrado: $CONFIG_FILE" >&2
    echo "        Copie backup.conf.example para $CONFIG_FILE e ajuste os valores." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Defaults (antes da validação para que LOG_FILE esteja disponível para die())
LOG_FILE="${LOG_FILE:-/var/log/backup-to-aws.log}"
UPLOAD_MODE="${UPLOAD_MODE:-stream}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-3}"
TEMP_DIR="${TEMP_DIR:-/var/tmp/backup-to-aws}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"

# Valida variáveis obrigatórias
for var in MYSQL_HOST MYSQL_PORT DATABASES S3_BUCKET S3_PREFIX AWS_REGION; do
    if [[ -z "${!var:-}" ]]; then
        die "Variável obrigatória não definida: $var"
    fi
done

# Valida UPLOAD_MODE
if [[ "$UPLOAD_MODE" != "stream" && "$UPLOAD_MODE" != "local" ]]; then
    die "UPLOAD_MODE inválido: '${UPLOAD_MODE}' (use 'stream' ou 'local')"
fi

# Valida GZIP_LEVEL
if [[ ! "$GZIP_LEVEL" =~ ^[1-9]$ ]]; then
    die "GZIP_LEVEL deve ser um número entre 1 e 9"
fi

if [[ ! -f "$MYCNF_FILE" ]]; then
    die "Arquivo de credenciais MySQL não encontrado: $MYCNF_FILE"
fi

if [[ "$UPLOAD_MODE" == "local" ]]; then
    mkdir -p "$TEMP_DIR"
fi

# Garante que o diretório de log existe
mkdir -p "$(dirname "$LOG_FILE")"

# =============================================================================
# Lock — evita execuções simultâneas
# =============================================================================

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    die "Outra instância já está em execução (lock: $LOCK_FILE)"
fi
trap 'rm -f "$LOCK_FILE"' EXIT

# =============================================================================
# Início
# =============================================================================

START_TIME="$(date +%s)"
log_info "========== Backup iniciado — $(date) =========="
log_info "Host: ${MYSQL_HOST}:${MYSQL_PORT} | Modo: ${UPLOAD_MODE} | Compressão: gzip -${GZIP_LEVEL}"

# =============================================================================
# Resolve lista de bancos
# =============================================================================

resolve_databases() {
    if [[ "$DATABASES" == "ALL" ]]; then
        mysql --defaults-extra-file="$MYCNF_FILE" \
              -h "$MYSQL_HOST" -P "$MYSQL_PORT" \
              -N -e "SHOW DATABASES" \
            | grep -Ev '^(information_schema|performance_schema|mysql|sys)$'
    else
        echo "$DATABASES" | tr ' ' '\n'
    fi
}

DB_LIST="$(resolve_databases)"
if [[ -z "$DB_LIST" ]]; then
    die "Nenhum banco de dados encontrado para backup"
fi

DB_COUNT="$(echo "$DB_LIST" | wc -l)"
log_info "Bancos para backup (${DB_COUNT}): $(echo "$DB_LIST" | tr '\n' ' ')"

# =============================================================================
# Backup de um banco (stream)
# =============================================================================

backup_stream() {
    local db="$1"
    local s3_key="s3://${S3_BUCKET}/${S3_PREFIX}/${db}/${db}_${TIMESTAMP}.sql.gz"

    log_info "[${db}] Iniciando backup (stream) → ${s3_key}"
    local db_start
    db_start="$(date +%s)"

    set +e
    mysqldump --defaults-extra-file="$MYCNF_FILE" \
              -h "$MYSQL_HOST" -P "$MYSQL_PORT" \
              --single-transaction --quick --skip-lock-tables \
              --routines --triggers --events \
              "$db" \
        | gzip -"$GZIP_LEVEL" \
        | aws s3 cp - "$s3_key" \
              --region "$AWS_REGION"
    local -a pipe_status=("${PIPESTATUS[@]}")
    set -e

    if [[ "${pipe_status[0]}" -ne 0 ]]; then
        log_error "[${db}] mysqldump falhou (exit ${pipe_status[0]})"
        return 1
    fi
    if [[ "${pipe_status[1]}" -ne 0 ]]; then
        log_error "[${db}] gzip falhou (exit ${pipe_status[1]})"
        return 1
    fi
    if [[ "${pipe_status[2]}" -ne 0 ]]; then
        log_error "[${db}] aws s3 cp falhou (exit ${pipe_status[2]})"
        return 1
    fi

    local db_end duration
    db_end="$(date +%s)"
    duration="$(( db_end - db_start ))"
    log_info "[${db}] Backup concluído em ${duration}s"
}

# =============================================================================
# Backup de um banco (local)
# =============================================================================

backup_local() {
    local db="$1"
    local dump_file="${TEMP_DIR}/${db}_${TIMESTAMP}.sql.gz"
    local s3_key="s3://${S3_BUCKET}/${S3_PREFIX}/${db}/${db}_${TIMESTAMP}.sql.gz"

    log_info "[${db}] Iniciando backup (local) → ${dump_file}"
    local db_start
    db_start="$(date +%s)"

    set +e
    mysqldump --defaults-extra-file="$MYCNF_FILE" \
              -h "$MYSQL_HOST" -P "$MYSQL_PORT" \
              --single-transaction --quick --skip-lock-tables \
              --routines --triggers --events \
              "$db" \
        | gzip -"$GZIP_LEVEL" > "$dump_file"
    local -a pipe_status=("${PIPESTATUS[@]}")
    set -e

    if [[ "${pipe_status[0]}" -ne 0 ]]; then
        log_error "[${db}] mysqldump falhou (exit ${pipe_status[0]})"
        rm -f "$dump_file"
        return 1
    fi
    if [[ "${pipe_status[1]}" -ne 0 ]]; then
        log_error "[${db}] gzip falhou (exit ${pipe_status[1]})"
        rm -f "$dump_file"
        return 1
    fi

    local file_size
    file_size="$(du -h "$dump_file" | cut -f1)"
    log_info "[${db}] Dump local: ${dump_file} (${file_size})"

    log_info "[${db}] Enviando para S3 → ${s3_key}"
    if ! aws s3 cp "$dump_file" "$s3_key" --region "$AWS_REGION"; then
        log_error "[${db}] Upload para S3 falhou"
        return 1
    fi

    local db_end duration
    db_end="$(date +%s)"
    duration="$(( db_end - db_start ))"
    log_info "[${db}] Backup concluído em ${duration}s (${file_size})"
}

# =============================================================================
# Loop por banco
# =============================================================================

while IFS= read -r db; do
    [[ -z "$db" ]] && continue

    if [[ "$UPLOAD_MODE" == "stream" ]]; then
        backup_fn=backup_stream
    else
        backup_fn=backup_local
    fi

    if $backup_fn "$db"; then
        SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        FAILED_DBS="${FAILED_DBS}  - ${db}"$'\n'
    fi
done <<< "$DB_LIST"

# =============================================================================
# Limpeza e resumo
# =============================================================================

cleanup_local

END_TIME="$(date +%s)"
TOTAL_DURATION="$(( END_TIME - START_TIME ))"

log_info "========== Backup finalizado — $(date) =========="
log_info "Duração total: ${TOTAL_DURATION}s | Sucesso: ${SUCCESS_COUNT} | Falha: ${FAIL_COUNT}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    log_error "Bancos com falha:"
    while IFS= read -r line; do
        [[ -n "$line" ]] && log_error "$line"
    done <<< "$FAILED_DBS"
    send_notification
    exit 1
fi

exit 0
