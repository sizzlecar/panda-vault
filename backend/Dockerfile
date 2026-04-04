FROM rust:1.85-bookworm AS builder

WORKDIR /app

COPY backend/Cargo.toml ./backend/Cargo.toml
COPY backend/Cargo.lock ./backend/Cargo.lock
RUN mkdir -p backend/src && echo "fn main(){}" > backend/src/main.rs
RUN cargo build --release --locked --manifest-path backend/Cargo.toml

COPY backend ./backend
RUN cargo build --release --locked --manifest-path backend/Cargo.toml

# 说明：在部分网络/代理环境下，build 阶段拉 debian 的 token/manifest 可能不稳定。
# 为了提升可用性，这里直接复用 rust:bookworm 作为运行时基础镜像（你已验证 docker pull rust 可用）。
# 后续若网络稳定，可再切回 debian:bookworm-slim 做瘦身优化。
FROM rust:1.85-bookworm

# 某些网络/代理环境会对纯 HTTP 访问返回 405，这里强制将 apt 源切到 HTTPS
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true \
  && sed -i 's|http://security.debian.org|https://security.debian.org|g' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true \
  && apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/backend/target/release/panda-vault-backend /usr/local/bin/panda-vault-backend

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/panda-vault-backend"]

