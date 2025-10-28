# k8s-janitor

A lightweight Kubernetes CronJob that deletes ephemeral namespaces once they exceed a configurable age and posts a summary to Slack or any HTTP-based email gateway.

## What it does

1. Runs nightly at 02:00 UTC.
2. Lists namespaces and filters them by a regex (`NAMESPACE_REGEX`).
3. Deletes matching namespaces older than `MAX_NAMESPACE_AGE_HOURS` (default 26h) with `kubectl delete namespace --wait=false`.
4. Sends a report to Slack (default) or an email webhook describing what was deleted or if anything failed.

## Repository layout

```
chart/
  namespace-janitor/       # Helm chart (templates + packaged script/denylist)
config/
  namespace-denylist.txt   # Regex patterns for namespaces that must never be deleted
tools/
  helm_helper.py           # Helper CLI to install/debug/remove the chart locally
```

## Deployment

### 1. Create the namespace (optional) and alert secret

If you do not pass `--create-namespace` to Helm, create it manually:

```bash
kubectl create namespace janitor
```

Then create a secret that stores the Slack webhook (and optional email fields). You can either let Helm create it (not recommended for production because it bakes credentials into the release manifest) or provision it separately:

```bash
kubectl create secret generic namespace-janitor-alerts \
  -n janitor \
  --from-literal=slack-webhook-url=https://hooks.slack.com/services/XXX/YYY/ZZZ \
  --from-literal=alert-email-endpoint=https://example.com/email-gateway \
  --from-literal=alert-email-to=ops@example.com
```

(Only the Slack webhook is required when `alertMode=slack`.)

### 2. Install with Helm (recommended)

```bash
helm upgrade --install namespace-janitor ./chart/namespace-janitor \
  --namespace janitor \
  --set alertSecret.name=namespace-janitor-alerts
```

Append `--create-namespace` if you want Helm to create the namespace for you.

Pass a custom values file or inline overrides to tweak regexes, schedules, denylist entries, or to let Helm create the secret for you:

```bash
helm upgrade --install namespace-janitor ./chart/namespace-janitor \
  --namespace janitor \
  -f my-values.yaml
```

Example snippet (`my-values.yaml`) that adds a denylist entry and lets Helm create the alert secret (fine for demos):

```yaml
alertSecret:
  create: true
  name: namespace-janitor-alerts
  data:
    slack-webhook-url: https://hooks.slack.com/services/XXX/YYY/ZZZ
denylist:
  entries:
    - "^kube-.*"
    - "^default$"
    - "^prod-[a-z0-9]+$"
```

### 3. Use the helper CLI for local testing

The repo ships with a small Python wrapper that simplifies repeat install/delete/debug cycles when you are iterating locally (e.g., on Minikube or kind):

```
python tools/helm_helper.py install --safe --create-namespace
python tools/helm_helper.py debug
python tools/helm_helper.py uninstall
```

- `install` wraps `helm upgrade --install`. `--safe` applies the dry-run-friendly overrides described earlier (no real alerts, `dryRun=true`, `maxNamespaceAgeHours=0`).
- `debug` dumps pod status plus CronJob logs for the current release.
- `uninstall` removes the release from the target namespace.
- Append `--values my-values.yaml` or any other `helm` flags after `--` to pass them through.

### Testing the chart on Minikube

1. Start or reuse a local cluster:
   ```bash
   minikube start
   ```
2. Install the chart safely using the helper:
   ```bash
   python tools/helm_helper.py install --safe --create-namespace
   ```
3. Create a disposable namespace that matches the default regex:
   ```bash
   kubectl create namespace ephemeral-demo
   ```
4. Trigger the CronJob manually:
   ```bash
   kubectl -n janitor create job --from=cronjob/namespace-janitor-namespace-janitor namespace-janitor-manual
   kubectl -n janitor logs job/namespace-janitor-manual -f
   ```
5. Tear down once done:
   ```bash
   python tools/helm_helper.py uninstall
   minikube delete # optional
   ```

## Configuration knobs

Control behavior with the following environment variables (surfaced via Helm values and injected into the CronJob).

| Variable | Default | Description |
| --- | --- | --- |
| `NAMESPACE_REGEX` | `^ephemeral-.*$` | Regex applied to namespace names before age filtering. |
| `NAMESPACE_DENYLIST_PATH` | unset | Optional path to a newline-delimited list of regexes that, when matched, force a namespace to be skipped (see `config/namespace-denylist.txt`). |
| `MAX_NAMESPACE_AGE_HOURS` | `26` | Threshold in hours before a namespace qualifies for deletion. |
| `ALERT_MODE` | `slack` | `slack`, `email`, or `none`. |
| `ALERT_SILENT_ON_EMPTY` | `true` | When `true`, skip alerts if nothing was deleted/failed. |
| `DRY_RUN` | `false` | If `true`, only log namespaces that would be deleted. |
| `SLACK_*` | see manifest/values | Customize Slack username/icon and provide `SLACK_WEBHOOK_URL`. |
| `ALERT_EMAIL_*` | unset | Optional email webhook endpoint + recipients when `ALERT_MODE=email`. |

## Helm values reference

| Value | Default | Description |
| --- | --- | --- |
| `schedule` | `0 2 * * *` | Cron expression. |
| `namespaceRegex` | `^ephemeral-.*$` | Matches namespaces eligible for deletion. |
| `denylist.entries` | `["^kube-.*","^default$","^prod-.*"]` | Regex patterns that the script must never delete. Disable by setting `denylist.enabled=false`. |
