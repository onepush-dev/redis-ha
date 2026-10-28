# Redis HA router: HAProxy that follows the current Redis primary.
# :6379 read-write (node reporting role:master), :6380 read-only (replicas, falls back to primary),
# :8080/health for Railway and /status for primary/replica counts.
FROM haproxy:3.4.7-alpine@sha256:2caaf8b1a1ef67f3f1ea9b721f2821675d3ba4500fb518e23884fecb93e8dbaa
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
ENV HAPROXY_MAXCONN=10000 \
    HAPROXY_TIMEOUT_CLIENT=30m \
    HAPROXY_TIMEOUT_SERVER=30m \
    HAPROXY_CHECK_INTERVAL=1s \
    REDIS_PORT=6379
EXPOSE 6379 6380 8080
