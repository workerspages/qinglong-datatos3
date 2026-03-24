#!/bin/bash
# ============================================================================
# entrypoint.sh - 青龙面板数据持久化入口脚本
# 在青龙面板启动前恢复数据，并启动后台定时备份循环
# ============================================================================

set -eo pipefail

LOG_PREFIX="[ENTRY]"
SYNC_INTERVAL="${SYNC_INTERVAL:-5}"

log_info() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warn() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
}

log_error() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# --- 后台定时备份循环 ---
# 使用独立后台进程替代 crontab，避免被青龙面板的 cron 管理覆盖
backup_loop() {
    local interval_seconds=$(( SYNC_INTERVAL * 60 ))
    log_info "后台备份循环已启动 (间隔: ${SYNC_INTERVAL} 分钟)"

    while true; do
        sleep "${interval_seconds}"
        log_info "定时备份触发..."
        if /usr/local/bin/sync.sh backup >> /var/log/sync.log 2>&1; then
            log_info "定时备份完成！(耗时明细见 /var/log/sync.log)"
        else
            log_warn "定时备份执行失败，将在下一周期重试"
        fi
    done
}

# --- 数据同步初始化 ---
init_sync() {
    if [[ -z "${STORAGE_TYPE:-}" ]]; then
        log_warn "STORAGE_TYPE 未设置，跳过数据同步（数据不会持久化）"
        return 0
    fi

    log_info "========================================="
    log_info "  开始数据同步初始化"
    log_info "  存储类型: ${STORAGE_TYPE}"
    log_info "  加密状态: $([ -n "${ENCRYPT_PASSWORD:-}" ] && echo '已启用' || echo '未启用')"
    log_info "  同步间隔: ${SYNC_INTERVAL} 分钟"
    log_info "========================================="

    # 配置 rclone + 恢复数据
    if /usr/local/bin/sync.sh restore; then
        log_info "数据同步初始化成功！"
    else
        log_error "数据同步初始化失败！但将继续启动青龙面板..."
    fi

    # 启动后台备份循环（独立于系统 cron）
    backup_loop &
    BACKUP_PID=$!
    log_info "后台备份进程已启动 (PID: ${BACKUP_PID})"

    log_info "========================================="
}


# --- 主流程 ---
log_info "========================================"
log_info "  青龙面板 (S3/WebDAV 数据持久化版)"
log_info "========================================"

# 1. 初始化数据同步 + 启动后台备份
init_sync

# (已移除端口转发，按照用户要求使用原生 5700 端口)

# 3. 启动青龙面板原始入口
log_info "启动青龙面板..."
exec /ql/docker/docker-entrypoint.sh "$@"
