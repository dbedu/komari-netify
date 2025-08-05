#---------------------------------
# Stage 1: Build Frontend
#---------------------------------
FROM node:23-alpine AS frontend-builder
WORKDIR /app

# 创建前端构建目录
RUN mkdir -p /app

# 复制前端代码 (假设前端代码已经在构建上下文中)
COPY ./public/dist/ /app/dist/

# 注意：此处不再从远程仓库克隆，而是假设前端资源已经在本地准备好

#---------------------------------
# Stage 2: Build Backend
#---------------------------------
FROM golang:1.23-alpine AS backend-builder

# 安装 Zig 用于 CGO 静态编译
RUN apk add --no-cache zig

WORKDIR /app

# 仅复制 Go 模块文件以利用层缓存
COPY go.mod go.sum ./
# 下载依赖，这一层会被缓存
RUN go mod download

# 复制所有剩余的源代码
COPY . .

# 使用 BuildKit 的内置变量 TARGETARCH 来进行跨平台编译
# 定义构建参数，可以从外部传入版本信息
ARG VERSION="dev"
ARG VERSION_HASH="unknown"
ARG TARGETARCH

# 设置 LDFLAGS
ENV LDFLAGS="-s -w -X github.com/dbedu/komari-netify/utils.CurrentVersion=${VERSION} -X github.com/dbedu/komari-netify/utils.VersionHash=${VERSION_HASH}"

# 编译 Go 应用。Zig 的目标架构需要从 arm64 映射到 aarch64
RUN <<EOT
set -e
if [ "${TARGETARCH}" = "arm64" ]; then
    ZIG_TARGET="aarch64-linux-musl"
else
    ZIG_TARGET="x86_64-linux-musl"
fi
CC="zig cc -target ${ZIG_TARGET}" CGO_ENABLED=1 go build -trimpath -ldflags="${LDFLAGS}" -o /komari
EOT

#---------------------------------
# Stage 3: Final Image
#---------------------------------
FROM scratch

# 设置工作目录
WORKDIR /app

# 从后端构建器复制编译好的二进制文件
COPY --from=backend-builder /komari /app/komari

# 从前端构建器复制构建好的静态资源
COPY --from=frontend-builder /app/dist/ /app/public/dist/

# 暴露端口
EXPOSE 25774

VOLUME ["/app/data"]

CMD ["/app/komari", "server", "-l", "0.0.0.0:25774"]