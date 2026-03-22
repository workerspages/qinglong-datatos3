# 青龙面板 - S3/WebDAV 数据持久化版

[![Docker Build](https://github.com/workerspages/qinglong-datatos3/actions/workflows/docker-build.yml/badge.svg)](https://github.com/workerspages/qinglong-datatos3/actions/workflows/docker-build.yml)

基于 [青龙面板](https://github.com/whyour/qinglong) 官方镜像，支持将数据**加密**后自动同步到 **S3 存储桶** 或 **WebDAV 网盘**，适用于没有持久化存储卷的 PaaS 平台。

## 工作原理

```
容器启动 → 从 S3/WebDAV 恢复数据 → 启动青龙面板 → 每 N 分钟自动备份数据到 S3/WebDAV
```

1. **启动时恢复**: 容器启动时使用 `rclone copy` 从远端拉取数据到 `/ql/data`
2. **定时备份**: 通过 cron 定时使用 `rclone sync` 将数据同步到远端
3. **优雅关闭**: 容器关闭时自动执行最后一次备份
4. **数据加密**: 可选 AES-256 加密，文件名和内容均加密后再上传

## 镜像地址

```bash
# GitHub Container Registry
docker pull ghcr.io/workerspages/qinglong-datatos3:latest

# Docker Hub
docker pull workerspages/qinglong-datatos3:latest
```

## 环境变量

| 变量名 | 必填 | 说明 | 默认值 |
|--------|------|------|--------|
| `STORAGE_TYPE` | ✅ | 存储类型: `s3` 或 `webdav` | - |
| `SYNC_INTERVAL` | ❌ | 同步间隔（分钟） | `5` |

### S3 配置（`STORAGE_TYPE=s3`）

| 变量名 | 必填 | 说明 | 默认值 |
|--------|------|------|--------|
| `S3_ENDPOINT` | ✅ | S3 端点 URL | - |
| `S3_ACCESS_KEY` | ✅ | Access Key | - |
| `S3_SECRET_KEY` | ✅ | Secret Key | - |
| `S3_BUCKET` | ✅ | 存储桶名称 | - |
| `S3_REGION` | ❌ | 区域 | `us-east-1` |
| `S3_PATH` | ❌ | 桶内子路径 | `qinglong` |

### WebDAV 配置（`STORAGE_TYPE=webdav`）

| 变量名 | 必填 | 说明 | 默认值 |
|--------|------|------|--------|
| `WEBDAV_URL` | ✅ | WebDAV 服务器 URL | - |
| `WEBDAV_USER` | ✅ | 用户名 | - |
| `WEBDAV_PASS` | ✅ | 密码 | - |
| `WEBDAV_VENDOR` | ❌ | 供应商类型 (`nextcloud`/`owncloud`/`other`) | `other` |
| `WEBDAV_PATH` | ❌ | 远端子路径 | `qinglong` |

### 加密配置（可选）

设置 `ENCRYPT_PASSWORD` 即可启用 AES-256 加密，数据在上传前会被自动加密（文件名 + 文件内容），下载时自动解密。

| 变量名 | 必填 | 说明 | 默认值 |
|--------|------|------|--------|
| `ENCRYPT_PASSWORD` | ❌ | 加密密码（设置后启用加密） | - |
| `ENCRYPT_SALT` | ❌ | 加密盐值（增强安全性） | - |

> ⚠️ **重要安全提示**：
> - 加密密码一旦设置后**不可更改或丢失**，否则已加密的备份数据将无法解密
> - 建议同时设置 `ENCRYPT_PASSWORD` 和 `ENCRYPT_SALT` 以获得最强安全性
> - 首次启用加密时，远端应为空目录；不能对已有的未加密备份直接启用加密

## 快速部署

### 使用 S3（Cloudflare R2 / MinIO / AWS S3 等）

```bash
docker run -d \
  --name qinglong \
  -p 5700:5700 \
  -e STORAGE_TYPE=s3 \
  -e S3_ENDPOINT=https://xxx.r2.cloudflarestorage.com \
  -e S3_ACCESS_KEY=your-access-key \
  -e S3_SECRET_KEY=your-secret-key \
  -e S3_BUCKET=your-bucket \
  -e ENCRYPT_PASSWORD=your-strong-encryption-password \
  -e ENCRYPT_SALT=your-random-salt \
  -e SYNC_INTERVAL=5 \
  ghcr.io/workerspages/qinglong-datatos3:latest
```

### 使用 WebDAV（坚果云 / Nextcloud 等）

```bash
docker run -d \
  --name qinglong \
  -p 5700:5700 \
  -e STORAGE_TYPE=webdav \
  -e WEBDAV_URL=https://dav.jianguoyun.com/dav \
  -e WEBDAV_USER=your-email \
  -e WEBDAV_PASS=your-app-password \
  -e WEBDAV_VENDOR=other \
  -e ENCRYPT_PASSWORD=your-strong-encryption-password \
  -e SYNC_INTERVAL=10 \
  ghcr.io/workerspages/qinglong-datatos3:latest
```

### 使用 Docker Compose

```bash
# 编辑 docker-compose.yml 中的环境变量
docker compose up -d
```

## PaaS 平台部署

在 PaaS 平台（如 Railway、Render、Fly.io 等）部署时，设置对应的环境变量即可：

1. 设置镜像为 `ghcr.io/workerspages/qinglong-datatos3:latest`
2. 配置端口映射: `5700 → 5700` (或直接暴露 `5700`)
3. 添加上述环境变量（根据存储类型选择 S3 或 WebDAV 的变量）
4. 首次启动后访问面板完成初始化设置

> **注意**: 建议将 `SYNC_INTERVAL` 设置为 5-10 分钟，避免过于频繁的同步影响性能。

## 本地构建

```bash
git clone https://github.com/workerspages/qinglong-datatos3.git
cd qinglong-datatos3
docker build -t qinglong-datatos3 .
```

## License

MIT