FROM whyour/qinglong:debian

LABEL maintainer="workerspages"
LABEL description="青龙面板 - S3/WebDAV 数据持久化版"

# 安装 rclone 和 Linux基础依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends rclone ca-certificates fuse && \
    apt-get install -y build-essential python3-dev python3-pip libssl-dev libffi-dev default-libmysqlclient-dev libjpeg-dev zlib1g-dev libcairo2-dev libpango1.0-dev libpixman-1-dev pkg-config rustc cargo && \
    rm -rf /var/lib/apt/lists/*

# 安装 Python3 常用依赖
RUN pip3 install dailycheckin aiohttp requests ping3 jieba curl-cffi --break-system-packages || pip3 install dailycheckin aiohttp requests ping3 jieba curl-cffi

# 安装 NodeJs 常用依赖
RUN pnpm add -g crypto-js prettytable dotenv jsdom date-fns tough-cookie tslib ws@7.4.3 ts-md5 jieba form-data json5 global-agent png-js @types/node typescript js-base64 axios got@11 canvas

# 复制同步脚本
COPY sync.sh /usr/local/bin/sync.sh
COPY entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/sync.sh /usr/local/bin/custom-entrypoint.sh

# 创建日志目录
RUN mkdir -p /var/log && touch /var/log/sync.log

# 使用默认 5700 端口
EXPOSE 5700

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
