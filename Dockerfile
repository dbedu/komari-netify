# Build stage
FROM golang:1.24-bookworm AS builder

# Install Zig compiler
RUN apt-get update && apt-get install -y wget xz-utils \
    && wget https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz \
    && tar -C /usr/local -Jxf zig-x86_64-linux-0.14.1.tar.xz \
    && rm zig-x86_64-linux-0.14.1.tar.xz
ENV PATH="/usr/local/zig-x86_64-linux-0.14.1:${PATH}"

WORKDIR /build

# Copy the source code
COPY . .

# Build the binary
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=1
ENV GIN_MODE=release

RUN if [ "$TARGETARCH" = "amd64" ]; then \
        CC="zig cc -target x86_64-linux-musl" go build -trimpath -o komari ; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        CC="zig cc -target aarch64-linux-musl" go build -trimpath -o komari ; \
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