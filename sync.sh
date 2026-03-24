#!/bin/bash
# ============================================================================
# sync.sh - 青龙面板数据同步脚本
# 支持 S3 和 WebDAV 两种存储后端，可选 AES-256 加密
# 使用 rclone 实现数据的备份/恢复
# ============================================================================

set -euo pipefail

# --- 常量定义 ---
RCLONE_CONF="/root/.config/rclone/rclone.conf"
REMOTE_NAME="remote"
CRYPT_REMOTE_NAME="encrypted"
QL_DATA_DIR="/ql/data"
LOCK_FILE="/tmp/sync.lock"
LOG_PREFIX="[SYNC]"

# ============================================================================
# 环境变量安全清理函数 (防止 PaaS UI 粘贴带来 \r \n 等不可见字符)
# ============================================================================
trim_string() {
    echo "$1" | tr -d '\r\n\t '
}
trim_password() {
    echo "$1" | tr -d '\r\n'
}

# --- 环境变量默认值 ---
STORAGE_TYPE=$(trim_string "${STORAGE_TYPE:-}")
SYNC_INTERVAL=$(trim_string "${SYNC_INTERVAL:-5}")

# S3 配置
S3_ENDPOINT=$(trim_string "${S3_ENDPOINT:-}")
S3_ACCESS_KEY=$(trim_string "${S3_ACCESS_KEY:-}")
S3_SECRET_KEY=$(trim_string "${S3_SECRET_KEY:-}")
S3_BUCKET=$(trim_string "${S3_BUCKET:-}")
S3_REGION=$(trim_string "${S3_REGION:-us-east-1}")
S3_PATH=$(trim_string "${S3_PATH:-qinglong}")

# WebDAV 配置
WEBDAV_URL=$(trim_string "${WEBDAV_URL:-}")
WEBDAV_USER=$(trim_string "${WEBDAV_USER:-}")
WEBDAV_PASS=$(trim_password "${WEBDAV_PASS:-}")
WEBDAV_VENDOR=$(trim_string "${WEBDAV_VENDOR:-other}")
WEBDAV_PATH=$(trim_string "${WEBDAV_PATH:-qinglong}")

# 加密配置
ENCRYPT_PASSWORD=$(trim_password "${ENCRYPT_PASSWORD:-}")
ENCRYPT_SALT=$(trim_password "${ENCRYPT_SALT:-}")

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

# 判断是否启用加密
is_encrypt_enabled() {
    [[ -n "${ENCRYPT_PASSWORD}" ]]
}

# 获取远端路径
get_remote_path() {
    if is_encrypt_enabled; then
        # 加密模式：使用 crypt 远端（路径已在 crypt 配置中指定）
        echo "${CRYPT_REMOTE_NAME}:"
    else
        # 非加密模式：直接使用基础远端
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
    fi
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

    # 配置加密层（如果启用）
    if is_encrypt_enabled; then
        log_info "加密已启用，配置 crypt 远端..."
        local base_path
        case "${STORAGE_TYPE}" in
            s3)
                base_path="${REMOTE_NAME}:${S3_BUCKET}/${S3_PATH}"
                ;;
            webdav)
                base_path="${REMOTE_NAME}:${WEBDAV_PATH}"
                ;;
        esac

        local obscured_encrypt_pass
        obscured_encrypt_pass=$(rclone obscure "${ENCRYPT_PASSWORD}")

        # 追加 crypt 远端配置
        cat >> "${RCLONE_CONF}" <<EOF

[${CRYPT_REMOTE_NAME}]
type = crypt
remote = ${base_path}
password = ${obscured_encrypt_pass}
filename_encryption = standard
directory_name_encryption = true
EOF

        # 如果提供了 salt，添加 password2
        if [[ -n "${ENCRYPT_SALT}" ]]; then
            local obscured_salt
            obscured_salt=$(rclone obscure "${ENCRYPT_SALT}")
            echo "password2 = ${obscured_salt}" >> "${RCLONE_CONF}"
        fi

        log_info "加密配置完成 (文件名加密: standard, 目录名加密: true)"
    else
        log_info "加密未启用（如需启用，请设置 ENCRYPT_PASSWORD 环境变量）"
    fi

    # 验证配置
    local check_remote="${REMOTE_NAME}"
    if is_encrypt_enabled; then
        check_remote="${CRYPT_REMOTE_NAME}"
    fi
    if rclone listremotes --config "${RCLONE_CONF}" | grep "^${check_remote}:" > /dev/null; then
        log_info "rclone 配置验证通过"
    else
        log_error "rclone 配置验证失败"
        log_info "=== 调试信息开始 [rclone.conf] ==="
        sed 's/access_key_id = .*/access_key_id = ****/g; s/secret_access_key = .*/secret_access_key = ****/g; s/pass = .*/pass = ****/g; s/password = .*/password = ****/g; s/password2 = .*/password2 = ****/g' "${RCLONE_CONF}" || true
        log_info "=== 调试信息开始 [listremotes] ==="
        rclone listremotes --config "${RCLONE_CONF}" || true
        log_info "=== 调试信息结束 ==="
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
    if rclone lsf "${remote_path}" --config "${RCLONE_CONF}" --max-depth 1 2>/dev/null | grep "." > /dev/null; then
        log_info "远端存在数据，正在恢复..."
        if rclone copy "${remote_path}" "${QL_DATA_DIR}" \
            --exclude "log/**" \
            --exclude "**/node_modules/**" \
            --exclude "**/.npm/**" \
            --exclude "**/.pnpm-store/**" \
            --exclude "**/.cache/**" \
            --exclude "**/.git/**" \
            --exclude "**/.github/**" \
            --exclude "**/__pycache__/**" \
            --timeout 10m \
            --contimeout 2m \
            --retries 3 \
            --retries-sleep 5s \
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

    # 强制 SQLite 触发 WAL Checkpoint，防止因 WAL 机制导致从 .sqlite-wal 备份不同步
    # 利用系统中必定包含的 python3 和 sqlite3 标准库完成
    if command -v python3 >/dev/null 2>&1; then
        for db in "${QL_DATA_DIR}/db/"*.sqlite "${QL_DATA_DIR}/db/"*.db; do
            if [[ -f "$db" ]]; then
                python3 -c "import sqlite3; con = sqlite3.connect('$db'); con.execute('PRAGMA wal_checkpoint(TRUNCATE)'); con.close()" 2>/dev/null || true
            fi
        done
        log_info "已触发所有 SQLite 数据库的 WAL Checkpoint"
    fi

    if rclone sync "${QL_DATA_DIR}" "${remote_path}" \
        --exclude "log/**" \
        --exclude "**/node_modules/**" \
        --exclude "**/.npm/**" \
        --exclude "**/.pnpm-store/**" \
        --exclude "**/.cache/**" \
        --exclude "**/.git/**" \
        --exclude "**/.github/**" \
        --exclude "**/__pycache__/**" \
        --timeout 10m \
        --contimeout 2m \
        --retries 3 \
        --retries-sleep 5s \
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
        *)
            echo "用法: $0 {configure|restore|backup}"
            echo ""
            echo "  configure  - 配置 rclone"
            echo "  restore    - 从远端恢复数据（含自动配置）"
            echo "  backup     - 备份数据到远端"
            return 1
            ;;
    esac
}

main "$@"
