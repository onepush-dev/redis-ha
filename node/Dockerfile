# Redis HA node: Redis 8.10 (with the built-in JSON, Search, TimeSeries and probabilistic modules)
# plus a colocated Sentinel. Three nodes = three Sentinels = quorum 2, with no extra services.
FROM redis:8.10.3-trixie@sha256:3466b24cc1232a254fc4753963cbe93392a30b3d24c2cad445fbc72c80b654a0

COPY --chmod=755 node.sh /usr/local/bin/redis-ha-node.sh

ENV REDIS_PORT=6379 \
    SENTINEL_PORT=26379 \
    REDIS_MASTER_NAME=mymaster

EXPOSE 6379 26379
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/redis-ha-node.sh"]
