# Topic 11 — Synthetic Monitoring: Checking From the Outside

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

This is roadmap step `11-synthetic-blackbox` (`LEARNING-ROADMAP.md` §11), mostly in `gitops`
(blackbox exporter, Probes, alerts, the "Is everything OK?" dashboard) with the AWS-managed
side here in `tf` (`infrastructure/app-cluster/01-infra/observability.tf`: a CloudWatch
Synthetics canary and Container Insights, both off by default). The user-facing guide is
`gitops/docs/SYNTHETIC-MONITORING.md`. DNS and TLS checks wait for the domain (step 03).

---

## 1. The concept

- **Whitebox** monitoring reads a system's own signals (metrics, logs, traces). **Blackbox**
  (synthetic) monitoring acts like a user and checks the answer. You need both: internal
  metrics can be green while users can't get in, and they need traffic to say anything.
- **A synthetic check should prove a path, not a process.** "The pod answers `/health`" is
  already known from readiness. "Sign-in with a made-up user is refused with 401" proves the
  routing, the service, its security chain and its database.
- **Where you probe from decides what you can see.** From inside the cluster you see the
  service; through the ingress you also see routing; from outside the cloud you also see
  DNS, the load balancer, its security group and TLS. Each vantage point misses everything
  in front of it.
- **Independent watchers.** If the cluster dies, in-cluster probes die with it. The
  Watchdog heartbeat (step 08) catches a dead alerting path; an outside canary catches a
  dead app even when nothing inside can report it.
- **Managed vs self-hosted.** Container Insights is one add-on and AWS runs it; the
  Prometheus stack is many charts that you run, tune and pay for in time. The trade is
  control and portability against effort.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `gitops/addons/applications/blackbox-exporter.yaml` | prometheus-blackbox-exporter 11.19.1 (exporter 0.28.0); two replicas in the cloud |
| `gitops/addons/values/common/blackbox-exporter.yaml` | *how* to probe: modules `http_2xx`, `http_2xx_online` (body must say ONLINE), `http_signin_rejected` (POST, expects exactly 401) |
| `gitops/observability/components/synthetic-probes` | *what* to probe: one `Probe` per service, straight to its Service; the overlay fills in the namespace |
| `gitops/observability/local/edge-probes.yaml` | the same checks through Traefik (`via="ingress"`) |
| `gitops/observability/base/synthetic-alerts.yaml` | EndpointDown, EndpointSlow, TLSCertificateExpiringSoon, SyntheticProberDown, SyntheticProbesMissing; 8 unit tests |
| `gitops/observability/base/dashboards/overview.json` | "Is everything OK?": checks, SLO budgets, firing alerts, platform health |
| `gitops/scripts/validate.sh` | also runs `blackbox_exporter --config.check` on every environment's rendered config |
| `app` repo, branch `fix/client-error-status` | 401/400/404 instead of 500 for client errors (§3.1) |
| `tf/.../01-infra/observability.tf` | canary (S3 bucket, Lambda role, pinned runtime, alarm → SNS) and the `amazon-cloudwatch-observability` add-on with its IRSA role |

Switching them on, in `environments/app-cluster/<env>.tfvars`:

```hcl
synthetics_base_url       = "http://<ALB DNS name>"   # https://<domain> after step 03
synthetics_alarm_email    = "you@example.com"          # optional; or subscribe PagerDuty/Slack
enable_container_insights = true                       # optional
```

---

## 3. Real incidents

### 3.1 The probe found a bug before it was deployed: wrong passwords were 500s

The planned check was "sign-in with an unknown user returns 401". Reading the code showed it
would return **500**: user-service's catch-all `@ExceptionHandler(Exception.class)` turned
Spring Security's `BadCredentialsException` into a 500 with an ERROR log. So did a malformed
JSON body, an unknown path and a wrong HTTP method, in both services. Every client mistake
counted against the availability SLO and could page someone.

The fix (app repo) extends `ResponseEntityExceptionHandler`, so Spring MVC's own exceptions
keep their 4xx, and maps `AuthenticationException` to 401. Then the opposite trap: when
MongoDB is unreachable, Spring Security wraps the database error in an
`InternalAuthenticationServiceException`, which *is* an `AuthenticationException`. Mapped to
401, the probe would have passed while nobody could sign in. `AuthenticationServiceException`
stays a logged 500. Lesson: a check is only as good as the status codes behind it; read what
"success" really means before you alert on it.

### 3.2 A replacement that rewrote the wrong objects

The Probes component fills `NAMESPACE` into each target's host with a Kustomize replacement
that selected `kind: Probe`. In the lab overlay that also matched the Traefik probes, turning
`traefik.traefik.svc` into `traefik.development.svc`: a check that would always fail. The
component's Probes now carry `app.kubernetes.io/component: service-probe` and the replacement
selects on it. Lesson: a component's replacements must select only its own objects.

### 3.3 A module rejected a perfectly good 200

Tested against a stub server, `http_2xx` failed on a 200: the chart merges its default module
(`valid_http_versions: [HTTP/1.1, HTTP/2.0]`) into ours, and the stub answered HTTP/1.0. The
real services answer HTTP/1.1, so nothing changed, but this is exactly how a probe of an old
appliance fails mysteriously. `debug=true` on `/probe` printed the reason at once. Lesson:
Helm merges maps; values you didn't write are still there (`helm template` shows them).

### 3.4 Synthetic failed logins look like an attack

The sign-in check fails a login for `synthetic-probe` twice a minute per probe, forever. Any
brute-force detection or account lockout counting failed logins would trip on it. Every probe
request carries a fixed User-Agent (`blackbox-exporter (synthetic probe)`, the canary's
`CloudWatchSynthetics/...`) so logs and detectors can exempt it. Lesson: tell the security
team about synthetic traffic before it tells you.

### 3.5 Pinning the canary runtime

`syn-nodejs-puppeteer` went from 9.x to 17.0 in about two years, and majors aren't backward
compatible: 13.1 renamed the modules the script imports (`Synthetics` →
`@aws/synthetics-puppeteer`). Taking "latest" would upgrade the canary on whatever apply came
next. The runtime is pinned (`synthetics_runtime_version`, 17.0), looked up at plan time, and a
`check` block warns on every plan once AWS schedules its deprecation.

### 3.6 Two AWS traps in the alarm path

- **SNS encryption.** CloudWatch alarms can't publish to a topic encrypted with the
  AWS-managed `aws/sns` key, because that key's policy can't grant CloudWatch. The topic is
  unencrypted (the messages hold no secrets); the alternative is a customer-managed key whose
  policy allows `cloudwatch.amazonaws.com`.
- **A new script at the same path is no change.** `aws_synthetics_canary` only sees
  `zip_file`'s path. The zip's name includes the script's hash, so editing the script updates
  the canary.

---

## 4. Verify — the full sequence

```bash
# gitops: config, rules, dashboard
cd gitops && ./scripts/validate.sh        # includes blackbox_exporter --config.check, 3 promtool test files

# Lab, after scripts/sync-local-stack.rb
kubectl get probes -n monitoring          # 6: three via=service, three via=ingress
kubectl port-forward svc/blackbox-exporter 9115 -n monitoring &
curl -s 'localhost:9115/probe?module=http_signin_rejected&target=http://user-service.development.svc.cluster.local/api/auth/signin' | grep probe_success
# Prometheus: probe_success{job="synthetic"}   all 1
# Grafana: "Is everything OK?"                 all green

# Break it (docs/SYNTHETIC-MONITORING.md "Try it in the lab"): scale order-service to 0
# → EndpointDown for both order-service checks after 2 minutes

# Cloud, with synthetics_base_url set
aws synthetics get-canary-runs --name dev-app-checks --max-results 3 --query 'CanaryRuns[].Status.State'
aws cloudwatch describe-alarms --alarm-names microservices-dev-synthetics-failing --query 'MetricAlarms[].StateValue'
```

The roadmap's own tests: *delete a DNS record → alert fires* waits for the domain (step 03).
*Block the ALB's security group → alert fires*: remove the inbound rule on the ALB's security
group; the canary alarm goes to ALARM after two failed runs (10 minutes), while every
in-cluster probe stays green. That difference is the point of probing from outside.

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| `kubectl get probes` has them, but no `probe_success` | Prometheus doesn't select them: they need the label `release: kube-prometheus-stack` |
| `probe_success` 0, `probe_http_status_code` 0 | no answer: DNS name wrong (`<service>.<namespace>.svc.cluster.local`) or no ready endpoints |
| Sign-in check: status 500 | user-service couldn't check credentials, usually MongoDB; 200 means someone registered `synthetic-probe` with the probe's password |
| `Invalid HTTP version number` in `debug=true` | the endpoint answers HTTP/1.0 and the module allows 1.1 and 2 only (§3.3) |
| Alerts carry `namespace="monitoring"` | a Probe without a `namespace` label: the operator then uses the Probe's own namespace |
| Canary runs fail with `Cannot find module '@aws/synthetics-puppeteer'` | runtime older than 13.1 (the variable's validation should have stopped it) |
| Canary alarm stuck in ALARM with no runs | the canary is stopped or failing to start; `treat_missing_data = breaching` counts that as failing, on purpose |
| Alarm fires but no email | the SNS email subscription was never confirmed |

---

## 6. Exercise

1. Container Insights vs Prometheus: turn on `enable_container_insights` in dev for a day.
   Compare one pod's CPU in CloudWatch (Container Insights → Performance monitoring) with
   `rate(container_cpu_usage_seconds_total{pod="..."}[5m])` in Grafana, and the bill for
   both. Write down when you'd choose each (team size, need for custom app metrics, retention,
   alert routing, lock-in). Turn it off again.
2. Once the domain exists (step 03): add Probes for `https://<domain>/` and its API paths to
   `observability/<env>` with `via: public`, point `synthetics_base_url` at the domain, and
   watch `probe_ssl_earliest_cert_expiry` appear. Test the TLS alerts in the lab with a
   temporary Probe of `https://expired.badssl.com/`: the probe fails (`EndpointDown`), and
   with `insecure_skip_verify` in a test module you see the expiry date it would have
   alerted on.
3. Add a positive sign-in check: a dedicated synthetic user whose password lives in AWS
   Secrets Manager, read by the canary at run time (never in Git). What new risks does a real
   credential in a probe bring, and how would you limit them?
