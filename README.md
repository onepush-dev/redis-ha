# Redis HA — 3-node Redis 8.10 with Sentinel failover and an HAProxy router on Railway. Deploy on Railway with one click.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/TEMPLATE_CODE)

A production-style **Redis 8.10** high-availability cluster on Railway: three Redis nodes, each with a colocated **Sentinel**, and an **HAProxy** router that always sends writes to the current primary. Automatic failover, AOF + RDB persistence on every node, a read-only replica endpoint, and the Redis 8 modules (JSON, Search, TimeSeries, Bloom) loaded out of the box.

## Features

- **3 Redis nodes + 3 Sentinels (quorum 2)** — no extra Sentinel services; any node can become primary
- **HAProxy router** — `:6379` read/write (always the node reporting `role:master`), `:6380` read-only (healthy replicas, falls back to the primary), `:8080/health` for Railway and `/status` for primary/replica counts
- **Redis 8.10.3** with the bundled **RedisJSON, Redis Query Engine (Search), TimeSeries and probabilistic (Bloom/Cuckoo/…)** modules
- **AOF (`everysec`) + RDB snapshots** on a volume per node; diskless replication between nodes
- **Self-healing restarts** — a restarted node asks the Sentinels who the primary is and rejoins as a replica
- **One generated secret** — `REDIS_PASSWORD` is generated on `redis-1` per deploy and referenced by the other nodes and the router
- **Sentinel-aware clients welcome** — `REDIS_SENTINEL_HOSTS` and `REDIS_MASTER_NAME` are exported on the router for ioredis / redis-py / Lettuce Sentinel mode
- **Drop-in variable names** — the router service is named `Redis` and exposes `REDIS_URL`, `REDISHOST`, `REDISPORT`, `REDISUSER`, `REDISPASSWORD` like Railway's single-node Redis

## Services

| Service | Image | Role | Volume |
| --- | --- | --- | --- |
| **redis-1** / **redis-2** / **redis-3** | `ghcr.io/onepush-dev/redis-ha-node:8.10.3` | Redis 8.10.3 + Sentinel | `/data` |
| **Redis** (router) | `ghcr.io/onepush-dev/redis-ha-router:8.10.3` (HAProxy 3.4.7) | Client endpoint + TCP proxy | none |

## How to connect

Open the **Redis** (router) service → Variables:

| Variable | Use |
| --- | --- |
| `REDIS_URL` | Apps in the same Railway project (private network, read/write, always the primary) |
| `REDIS_READONLY_URL` | Read-heavy traffic inside the project (port 6380, replicas) |
| `REDIS_PUBLIC_URL` | Apps outside Railway (TCP proxy → primary) |
| `REDISHOST` / `REDISPORT` / `REDISUSER` / `REDISPASSWORD` | Split form of the private URL |
| `REDIS_SENTINEL_HOSTS` / `REDIS_MASTER_NAME` | Sentinel-aware clients (optional) |

Reference them from your app as `${{Redis.REDIS_URL}}`. Railway private networking is IPv6: for ioredis set `family: 0`; for BullMQ pass the same option to the connection.

```bash
redis-cli -u "$REDIS_PUBLIC_URL" INFO replication
```

After a failover, HAProxy closes sessions on the old primary; clients reconnect and land on the new one (most Redis clients retry automatically).

## Health

The router answers `GET /health` on port **8080** (Railway healthcheck) and `GET /status` with `primary_up=1 replicas_up=2` on a healthy cluster.

## Persistence and failover

- Each node has its own volume at `/data` (AOF + RDB). Do not delete a volume while the cluster is running.
- Losing one node is fine (2 of 3 Sentinels still agree). With two nodes down Sentinel cannot elect a new primary until a node returns.
- Sentinel marks the primary down after `SENTINEL_DOWN_AFTER_MS` (5 s) and promotes the most up-to-date replica.
- Change the password only by setting a new `REDIS_PASSWORD` on `redis-1` and redeploying all four services.

## Configuration (on `redis-1`, referenced by the other nodes)

| Variable | Default | Notes |
| --- | --- | --- |
| `REDIS_MAXMEMORY` | `0` | e.g. `512mb`; `0` = no limit |
| `REDIS_MAXMEMORY_POLICY` | `noeviction` | `allkeys-lru` for a pure cache |
| `REDIS_APPENDONLY` | `yes` | AOF persistence |
| `SENTINEL_DOWN_AFTER_MS` | `5000` | failure detection time |
| `SENTINEL_FAILOVER_TIMEOUT_MS` | `30000` | |
| `SENTINEL_QUORUM` | `2` | |
| `REDIS_MASTER_NAME` | `mymaster` | Sentinel master name |

## Repo layout

- `node/` — Dockerfile + `node.sh` (role discovery, Redis + Sentinel supervisor)
- `router/` — Dockerfile + `haproxy.cfg`
- Images are built by GitHub Actions and published to GHCR; the Railway template pins digests.

## License

MIT for this repo. Redis 8 is available under RSALv2 / SSPLv1 / AGPLv3 (see redis.io).
