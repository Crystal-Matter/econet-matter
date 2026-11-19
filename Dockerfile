FROM --platform=$BUILDPLATFORM 84codes/crystal:latest-alpine AS compile
WORKDIR /app

RUN apk add --no-cache \
    ca-certificates git gmp-dev openssl-dev yaml-dev zlib-dev

COPY shard.yml shard.lock ./
RUN shards install --production --frozen --skip-postinstall --skip-executables

COPY src/ src/

# Run the Crystal compiler on the builder's native platform.
ARG TARGETARCH
RUN case "$TARGETARCH" in \
        amd64) target=x86_64-alpine-linux-musl ;; \
        arm64) target=aarch64-alpine-linux-musl ;; \
        *) printf 'Unsupported build architecture %s\n' "$TARGETARCH" >&2; exit 1 ;; \
    esac \
    && mkdir -p bin \
    && crystal build src/econet-matter.cr \
        --target "$target" --cross-compile --release --static --no-debug --threads=2 \
        -o /app/bin/econet-matter > /app/bin/link.sh

FROM 84codes/crystal:latest-alpine AS link
WORKDIR /app

RUN apk add --no-cache \
    ca-certificates \
    gmp-dev gmp-static \
    openssl-dev openssl-libs-static \
    tzdata \
    yaml-dev yaml-static \
    zlib-dev zlib-static

COPY --from=compile /app/bin/ /app/bin/
RUN /bin/sh /app/bin/link.sh \
    && addgroup -g 10001 appuser \
    && adduser -D -H -u 10001 -G appuser -s /sbin/nologin appuser \
    && install -d -m 0700 -o appuser -g appuser /app/data

FROM scratch
WORKDIR /

COPY --from=link /etc/passwd /etc/group /etc/
COPY --from=link /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=link /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=link --chown=10001:10001 /app/data /data
COPY --from=link /app/bin/econet-matter /econet-matter

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    MATTER_STORAGE_FILE=/data/econet-matter.yml

USER 10001:10001
EXPOSE 5540/udp
ENTRYPOINT ["/econet-matter"]
