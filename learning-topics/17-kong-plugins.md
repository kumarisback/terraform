# Topic 17 — Kong plugins: what a gateway is for

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `17-kong-plugins`. Mostly gitops (`platform/kong`, `apps/base/kong.yaml`,
`apps/base/routes.yaml`, credentials); in this repo the `jwt-public-key` secret and
`scripts/set-secret.sh`. The user guide is `gitops/docs/KONG.md`, "What the gateway checks".

---

## 1. The concept

- **Gateway or service?** Cross-cutting checks that stop a bad request before it costs
  anything belong at the gateway: authentication of the caller, rate limits, quotas, response
  headers. Decisions that need business data (may this user see this order?) belong in the
  service. Moving authorization into the gateway couples it to every service's data model.
- **Rate-limit algorithms.** Fixed window (count per calendar minute: cheap, but allows twice
  the limit across a window boundary), sliding window (weights the previous window: smooth),
  token bucket (refills at a rate, allows bursts up to the bucket size). Where the counter
  lives matters as much: per gateway process ("local") multiplies the limit by the number of
  pods; a shared store (Redis) makes it one limit.
- **Authentication by audience.** Browsers: sign-in tokens (JWT, OAuth2/OIDC). Partner
  applications: API keys per application (simple, revocable, tiered) or OAuth2 client
  credentials. Services inside: mutual TLS with platform-issued identities (step 18). Often two
  at once: an API key for the *application*, a user token for the *person*.
- **Plugin scope and order.** Kong resolves each plugin for a request from the most specific
  attachment (route and consumer, consumer, route, service, global), and runs plugins in a
  fixed priority order: authentication, then limits, then transformations, then the response.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `platform/kong/plugins.yaml` | `KongClusterPlugin`s: prometheus (`per_consumer`) and security-headers, both global; `auth-attempts` (10/min/IP), `partner-tier-basic` (60/min, 1,000/h) and `-premium` (600/min, 20,000/h), all `policy: redis`, `fault_tolerant`, password by `configPatches` from Secret `kong-redis`; `maintenance` (request-termination 503), attached nowhere |
| gitops `platform/kong/redis.yaml` | Valkey 8.1 (in memory, `--requirepass`, 64 MB, non-root, read-only root), NetworkPolicy: gateways only |
| gitops `apps/base/kong.yaml` | `user-tokens` (jwt: `iss` → consumer, `exp` verified, `maximum_expiration` 24 h, header only), `partner-keys` (key-auth, header only, `hide_credentials`), `partner-api-v1` (request-transformer); consumers `user-service-tokens`, `partner-basic`, `partner-premium` |
| gitops `apps/base/routes.yaml` | Routes split so each check applies only where it should: `user-service-auth` (Exact sign-in/up), `order-service-status` (open), `order-service` (tokens), `order-service-partner` (keys) |
| gitops `platform/kong-redis-password.yaml`, `apps/<env>/kong-credentials.yaml` | External Secrets' Password generator for the Valkey password and the partner keys (generated once, in the cluster); `user-service-jwt` from Secrets Manager, labelled as a Kong `jwt` credential |
| gitops `scripts/start-lab.sh` | The same three in the lab, once, into git-ignored files |
| this repo `01-infra` `out_of_band["jwt-public-key"]`, `scripts/set-secret.sh` | The public key next to the signing key; `jwt-public-key` mode derives it without rotating |
| gitops observability | `KongRateLimitStoreUnavailable` (tested); "Requests by consumer" and "Refused at the gateway" panels |

---

## 3. Real incidents

All found while designing or reading the plugins' sources; none on a cluster.

### 3.1 A limit that doubles with the replicas

Kong's simplest policy counts in each gateway process. The cloud runs two gateway pods, so "10
sign-in attempts a minute" would have been 20, and more as the gateways scale. The counters
went to a shared Valkey instead, with a password and a NetworkPolicy, and `fault_tolerant` so
that a Valkey outage turns limits off (alerted) rather than turning the application off.

### 3.2 The health check that would have needed a token

Kong attaches plugins to whole routes. With the token check on the `/api/orders` route, the
synthetic checks on `/api/orders/status`, which carry no token, would have got 401 and paged.
`/api/orders/status` became a route of its own (`Exact` match, no plugins); the longest match
wins, so it never reaches the checked route.

### 3.3 Tokens in URLs

Kong's jwt plugin accepts a token in the `jwt` query parameter by default, and key-auth an API
key in the query string. URLs end up in access logs (Kong's, Traefik's, the ALB's), browser
history and referrer headers. Both now read credentials only from headers
(`uri_param_names: []`, `key_in_query: false`); the log pipeline's masking stays as a second
line.

### 3.4 Rotating the key without locking users out

Kong needs user-service's *public* key. Storing it next to the private one made key rotation a
two-secret change: until External Secrets refreshes Kong's copy (an hour), the gateway refuses
every token signed with the new key. `set-secret.sh` writes both in one go and its header says
to force-sync both ExternalSecrets before restarting user-service. For environments that
already have a signing key, a `jwt-public-key` mode derives the public key from it, rather
than generating a new key and signing everyone out.

### 3.5 A password with a newline

The lab's Valkey password is generated with `openssl rand -hex 24 > file`, which ends the file
with a newline. `kubectl create secret --from-file` would have put that newline into the
password: Valkey and Kong would agree on it, but anyone typing the password into `valkey-cli`
would not. `--from-literal="$(cat file)"` strips it.

### 3.6 Ordering, not listing

A global request-transformer removing client-sent `X-Consumer-*` headers (so a client can't
pretend to be a consumer) looked like a good idea. Kong runs it after the authentication
plugins, though, so it would also remove the headers they set. The services don't read those
headers, so the transformer was left out; the lesson is that plugin order comes from
priorities, not from the order you write them in.

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh       # plugins, consumers, ExternalSecrets and generators against their CRDs; alert tests
cd tf && terraform -chdir=infrastructure/app-cluster/01-infra validate

# Lab (docs/KONG.md "Try it", 3-4)
curl -s -o /dev/null -w '%{http_code}\n' localhost/api/orders/user/1          # 401 from Kong
curl -sI localhost/ | grep -i 'x-content-type-options\|x-frame-options'      # the security headers
kubectl exec -n kong deploy/kong-redis -- sh -c 'valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning dbsize'   # counters exist after a few requests
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| every `/api/orders` call 401 with a good token | Secret `user-service-jwt` missing or holding another key (rotation: force-sync it), or the token's `iss` isn't `user-service` |
| `/api/v1/orders` 401 with a key | the key's Secret lacks the label `konghq.com/credential: key-auth`, or the consumer's `credentials` list doesn't name it |
| limits never trigger | Valkey unreachable (`fault_tolerant` lets everything through; `KongRateLimitStoreUnavailable`), or the request comes from a different address each time |
| everyone limited together | Kong sees the edge's address, not the client's: `trusted_ips` / `real_ip_header` |
| a plugin seems ignored | `KongResourcesRejected` / the controller's log: a plugin referencing a missing Secret is left out |

---

## 6. Exercise

1. Replace fixed windows with a smoother scheme: compare `second`+`minute` limits with a
   sliding window, and measure what a client can push through across a boundary.
2. Give partners OAuth2 client credentials instead of API keys (Kong's `oauth2` plugin, or an
   identity provider). What changes for rotation and revocation?
3. Turn the security headers into a Content-Security-Policy for the frontend: list its sources,
   start with `Content-Security-Policy-Report-Only`, and read the reports.
4. Move the counters to ElastiCache (`enable_elasticache`) and compare the failure behaviour
   when the cache restarts.
