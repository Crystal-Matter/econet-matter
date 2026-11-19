FROM 84codes/crystal:latest-alpine AS build
WORKDIR /app

RUN apk add --no-cache \
    ca-certificates \
    git \
    gmp-dev gmp-static \
    openssl-dev openssl-libs-static \
    tzdata \
    yaml-dev yaml-static \
    zlib-dev zlib-static

COPY shard.yml shard.lock ./
RUN shards install --production --frozen --skip-postinstall --skip-executables

COPY src/ src/
RUN shards build econet-matter --production --release --static --no-debug --threads=2

RUN addgroup -g 10001 appuser \
    && adduser -D -H -u 10001 -G appuser -s /sbin/nologin appuser \
    && install -d -m 0700 -o appuser -g appuser /app/data

FROM scratch
WORKDIR /

COPY --from=build /etc/passwd /etc/group /etc/
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build --chown=10001:10001 /app/data /data
COPY --from=build /app/bin/econet-matter /econet-matter

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    MATTER_STORAGE_FILE=/data/econet-matter.yml

USER 10001:10001
EXPOSE 5540/udp
ENTRYPOINT ["/econet-matter"]
