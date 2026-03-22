#!/bin/bash
# ============================================================================
# sync.sh - 青龙面板数据同步脚本
# 支持 S3 和 WebDAV 两种存储后端
# 使用 rclone 实现数据的备份/恢复
# ============================================================================

set -euo pipefail

# --- 常量定义 ---
RCLONE_CONF="/root/.config/rclone/rclone.conf"
REMOTE_NAME="remote"
QL_DATA_DIR="/ql/data"
LOCK_FILE="/tmp/sync.lock"
LOG_PREFIX="[SYNC]"

# --- 环境变量默认值 ---
STORAGE_TYPE="${STORAGE_TYPE:-}"
SYNC_INTERVAL="${SYNC_INTERVAL:-5}"

# S3 配置
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_PATH="${S3_PATH:-qinglong}"

# WebDAV 配置
WEBDAV_URL="${WEBDAV_URL:-}"
WEBDAV_USER="${WEBDAV_USER:-}"
WEBDAV_PASS="${WEBDAV_PASS:-}"
WEBDAV_VENDOR="${WEBDAV_VENDOR:-other}"
WEBDAV_PATH="${WEBDAV_PATH:-qinglong}"

# ============================================================================
# 工具函数
# ============================================================================

log_info() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warn() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

log_error() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# 获取远端路径
get_remote_path() {
    case "${STORAGE_TYPE}" in
        s3)
            echo "${REMOTE_NAME}:${S3_BUCKET}/${S3_PATH}"
            ;;
        webdav)
            echo "${REMOTE_NAME}:${WEBDAV_PATH}"
            ;;
        *)
            log_error "未知的存储类型: ${STORAGE_TYPE}"
            return 1
            ;;
    esac
}

# ============================================================================
# 配置 rclone
# ============================================================================

configure_rclone() {
    log_info "配置 rclone (存储类型: ${STORAGE_TYPE})..."

    if [[ -z "${STORAGE_TYPE}" ]]; then
        log_error "STORAGE_TYPE 环境变量未设置，请设置为 's3' 或 'webdav'"
        return 1
    fi

    mkdir -p "$(dirname "${RCLONE_CONF}")"

    case "${STORAGE_TYPE}" in
        s3)
            if [[ -z "${S3_ENDPOINT}" || -z "${S3_ACCESS_KEY}" || -z "${S3_SECRET_KEY}" || -z "${S3_BUCKET}" ]]; then
                log_error "S3 必需的环境变量未设置: S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET"
                return 1
            fi
            cat > "${RCLONE_CONF}" <<EOF
[${REMOTE_NAME}]
type = s3
provider = Other
env_auth = false
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION}
acl = private
no_check_bucket = true
EOF
            log_info "S3 配置完成 (端点: ${S3_ENDPOINT}, 桶: ${S3_BUCKET})"
            ;;
        webdav)
            if [[ -z "${WEBDAV_URL}" || -z "${WEBDAV_USER}" || -z "${WEBDAV_PASS}" ]]; then
                log_error "WebDAV 必需的环境变量未设置: WEBDAV_URL, WEBDAV_USER, WEBDAV_PASS"
                return 1
            fi
            # 使用 rclone obscure 加密密码
            local obscured_pass
            obscured_pass=$(rclone obscure "${WEBDAV_PASS}")
            cat > "${RCLONE_CONF}" <<EOF
[${REMOTE_NAME}]
type = webdav
url = ${WEBDAV_URL}
vendor = ${WEBDAV_VENDOR}
user = ${WEBDAV_USER}
pass = ${obscured_pass}
EOF
            log_info "WebDAV 配置完成 (URL: ${WEBDAV_URL}, 供应商: ${WEBDAV_VENDOR})"
            ;;
        *)
            log_error "不支持的存储类型: ${STORAGE_TYPE}，请使用 's3' 或 'webdav'"
            return 1
            ;;
    esac

    # 验证配置
    if rclone listremotes --config "${RCLONE_CONF}" | grep -q "${REMOTE_NAME}:"; then
        log_info "rclone 配置验证通过"
    else
        log_error "rclone 配置验证失败"
        return 1
    fi
}

# ============================================================================
# 数据恢复（从远端拉取到本地）
# ============================================================================

restore_data() {
    local remote_path
    remote_path=$(get_remote_path)

    log_info "开始从远端恢复数据..."
    log_info "远端路径: ${remote_path}"
    log_info "本地路径: ${QL_DATA_DIR}"

    # 确保本地目录存在
    mkdir -p "${QL_DATA_DIR}"

    # 检查远端是否有数据
    if rclone lsf "${remote_path}" --config "${RCLONE_CONF}" --max-depth 1 2>/dev/null | head -1 | grep -q .; then
        log_info "远端存在数据，正在恢复..."
        if rclone copy "${remote_path}" "${QL_DATA_DIR}" \
            --config "${RCLONE_CONF}" \
            --transfers 4 \
            --checkers 8 \
            --log-level INFO \
            --stats 30s \
            --stats-one-line; then
            log_info "数据恢复成功！"
        else
            log_warn "数据恢复过程中出现错误，但将继续启动..."
        fi
    else
        log_info "远端没有数据（首次运行），跳过恢复步骤"
    fi
}

# ============================================================================
# 数据备份（从本地同步到远端）
# ============================================================================

backup_data() {
    local remote_path
    remote_path=$(get_remote_path)

    # 使用锁文件防止并发同步
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_pid
        lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_warn "上一次备份仍在进行中 (PID: ${lock_pid})，跳过本次备份"
            return 0
        else
            log_warn "发现过期的锁文件，清理中..."
            rm -f "${LOCK_FILE}"
        fi
    fi

    echo $$ > "${LOCK_FILE}"
    trap 'rm -f "${LOCK_FILE}"' EXIT

    log_info "开始备份数据到远端..."
    log_info "本地路径: ${QL_DATA_DIR}"
    log_info "远端路径: ${remote_path}"

    if rclone sync "${QL_DATA_DIR}" "${remote_path}" \
        --config "${RCLONE_CONF}" \
        --transfers 4 \
        --checkers 8 \
        --log-level INFO \
        --stats 30s \
        --stats-one-line; then
        log_info "数据备份成功！"
    else
        log_error "数据备份失败！"
        rm -f "${LOCK_FILE}"
        return 1
    fi

    rm -f "${LOCK_FILE}"
    trap - EXIT
}

# ============================================================================
# 安装 cron 定时任务
# ============================================================================

setup_cron() {
    local interval="${SYNC_INTERVAL}"
    log_info "设置定时备份 (间隔: ${interval} 分钟)..."

    # 导出所有需要的环境变量到文件，供 cron 使用
    local env_file="/tmp/sync_env.sh"
    cat > "${env_file}" <<EOF
export STORAGE_TYPE="${STORAGE_TYPE}"
export S3_ENDPOINT="${S3_ENDPOINT}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY}"
export S3_SECRET_KEY="${S3_SECRET_KEY}"
export S3_BUCKET="${S3_BUCKET}"
export S3_REGION="${S3_REGION}"
export S3_PATH="${S3_PATH}"
export WEBDAV_URL="${WEBDAV_URL}"
export WEBDAV_USER="${WEBDAV_USER}"
export WEBDAV_PASS="${WEBDAV_PASS}"
export WEBDAV_VENDOR="${WEBDAV_VENDOR}"
export WEBDAV_PATH="${WEBDAV_PATH}"
export SYNC_INTERVAL="${SYNC_INTERVAL}"
export PATH="${PATH}"
EOF
    chmod 600 "${env_file}"

    # 创建 cron 任务
    local cron_script="/usr/local/bin/sync-cron.sh"
    cat > "${cron_script}" <<'CRONEOF'
#!/bin/bash
source /tmp/sync_env.sh
/usr/local/bin/sync.sh backup >> /var/log/sync.log 2>&1
CRONEOF
    chmod +x "${cron_script}"

    # 添加到 crontab
    echo "*/${interval} * * * * ${cron_script}" | crontab -

    log_info "cron 定时任务已设置"
}

# ============================================================================
# 主入口
# ============================================================================

main() {
    local action="${1:-}"

    case "${action}" in
        configure)
            configure_rclone
            ;;
        restore)
            configure_rclone
            restore_data
            ;;
        backup)
            backup_data
            ;;
        setup-cron)
            setup_cron
            ;;
        init)
            # 完整初始化流程：配置 → 恢复 → 设置 cron
            configure_rclone
            restore_data
            setup_cron
            ;;
        *)
            echo "用法: $0 {configure|restore|backup|setup-cron|init}"
            echo ""
            echo "  configure  - 配置 rclone"
            echo "  restore    - 从远端恢复数据"
            echo "  backup     - 备份数据到远端"
            echo "  setup-cron - 设置定时备份 cron 任务"
            echo "  init       - 完整初始化（配置 + 恢复 + cron）"
            return 1
            ;;
    esac
}

main "$@"
