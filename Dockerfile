FROM whyour/qinglong:debian

LABEL maintainer="workerspages"
LABEL description="青龙面板 - S3/WebDAV 数据持久化版"

# 安装 rclone 和依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends rclone ca-certificates fuse && \
    rm -rf /var/lib/apt/lists/*

# 复制同步脚本
COPY sync.sh /usr/local/bin/sync.sh
COPY entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/sync.sh /usr/local/bin/custom-entrypoint.sh

# 创建日志目录
RUN mkdir -p /var/log && touch /var/log/sync.log

# 使用 CloudFlare 兼容端口
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
