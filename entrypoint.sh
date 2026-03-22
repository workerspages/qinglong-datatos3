#!/bin/bash
# ============================================================================
# entrypoint.sh - 青龙面板数据持久化入口脚本
# 在青龙面板启动前恢复数据，并设置定时备份
# ============================================================================

set -eo pipefail

LOG_PREFIX="[ENTRY]"

log_info() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warn() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
}

log_error() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
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
    log_info "========================================="

    # 初始化同步（配置 + 恢复 + cron）
    if /usr/local/bin/sync.sh init; then
        log_info "数据同步初始化成功！"
    else
        log_error "数据同步初始化失败！但将继续启动青龙面板..."
    fi

    log_info "========================================="
}

# --- 容器关闭时的优雅处理 ---
graceful_shutdown() {
    log_info "收到关闭信号，执行最后一次数据备份..."
    if [[ -n "${STORAGE_TYPE:-}" ]]; then
        /usr/local/bin/sync.sh backup || log_warn "关闭前的备份失败"
    fi
    log_info "数据备份完成，正在关闭..."
    exit 0
}

# 捕获关闭信号
trap graceful_shutdown SIGTERM SIGINT SIGHUP

# --- 主流程 ---
log_info "========================================"
log_info "  青龙面板 (S3/WebDAV 数据持久化版)"
log_info "========================================"

# 1. 初始化数据同步
init_sync

# 2. 启动青龙面板原始入口
log_info "启动青龙面板..."
exec /ql/docker/docker-entrypoint.sh "$@"
