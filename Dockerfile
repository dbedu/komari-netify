# Build stage
FROM golang:1.24-bookworm AS builder

# Install Zig compiler
RUN apt-get update && apt-get install -y wget xz-utils \
    && wget https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz \
    && tar -C /usr/local -Jxf zig-x86_64-linux-0.14.1.tar.xz \
    && rm zig-x86_64-linux-0.14.1.tar.xz
ENV PATH="/usr/local/zig-x86_64-linux-0.14.1:${PATH}"

WORKDIR /build

# Copy go.mod and go.sum first to leverage Docker cache
COPY go.mod go.sum ./
RUN go mod download

# Copy the source code
COPY . .

# Build the binary
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=1
ENV GIN_MODE=release

# Set timeout for go commands to prevent hanging
ENV GO_BUILD_TIMEOUT=10m

RUN if [ "$TARGETARCH" = "amd64" ]; then \
        CC="zig cc -target x86_64-linux-musl" go build -trimpath -o komari ; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        # Use timeout to prevent hanging builds
        timeout $GO_BUILD_TIMEOUT CC="zig cc -target aarch64-linux-musl" go build -trimpath -o komari || \
        # Fallback to native Go build if Zig times out
        echo "Zig build timed out, falling back to native Go build" && \
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o komari ; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi

# Final stage
FROM debian:12-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the binary from builder
COPY --from=builder /build/komari /app/
COPY --from=builder /build/public /app/public

EXPOSE 25774

VOLUME ["/app/data"]

CMD ["/app/komari", "server", "-l", "0.0.0.0:25774"]