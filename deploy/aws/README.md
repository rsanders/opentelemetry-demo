# OpenTelemetry Demo on AWS (us-east-1)

Deploys the demo's core services (`compose.yaml`) onto a single EC2 instance
and forwards everything the `otel-collector` service sees into CloudWatch:

- **Metrics** → CloudWatch, via the `otlphttp` exporter pointed at CloudWatch's
  OpenTelemetry metrics endpoint (`https://monitoring.<region>.amazonaws.com/v1/metrics`),
  signed with the `sigv4auth` extension. These land in CloudWatch's OTel metric
  store and are queried with PromQL in Query Studio — not as a classic
  namespace in the Metrics console.
- **Logs** → CloudWatch Logs, via one `otlphttp` exporter per service, all
  pointed at CloudWatch's OpenTelemetry logs endpoint
  (`https://logs.<region>.amazonaws.com/v1/logs`), also `sigv4auth`-signed.
  The log group/stream go in the `x-aws-log-group`/`x-aws-log-stream` headers
  rather than the URL, and those headers are static per exporter — there's no
  per-record templating on this endpoint — so a `routing` connector splits the
  logs pipeline by `service.name` first, giving each service its own log
  stream under `/otel-demo/logs` instead of one shared stream. A service not
  in that routing table (see `otelcol-config-extras-aws.yml.j2`) still gets
  exported, just bucketed into a shared `other` stream. The collector's own
  self-telemetry logs go to a separate `/otel-demo/otelcol` group instead, so
  they don't turn up in searches or trace/log correlations scoped to the app
  services' group.
  - **`flagd` stdout bridge.** flagd v0.16 can export metrics and traces over
    OTLP but has no OTLP logs exporter. Its Docker logging driver sends stdout
    over Fluent Forward to a loopback-only collector receiver, where a
    dedicated pipeline assigns `service.name=flagd` and routes the records to
    the same OTLP/HTTP CloudWatch logs exporter as every other service. The
    records still lack trace_id/span_id, so they are visible in the `flagd`
    stream but not CloudWatch's "logs for this trace" panel. Because Docker is
    using a remote logging driver, `docker logs flagd` is unavailable.
- **Traces** → CloudWatch, via the `otlphttp` exporter pointed at CloudWatch's
  OpenTelemetry traces endpoint (`https://xray.<region>.amazonaws.com/v1/traces`),
  also `sigv4auth`-signed (SigV4 service name `xray` — same X-Ray ingestion API
  as the classic exporter, different wire format). Visible in the CloudWatch
  console under Traces / ServiceLens. Requires [Transaction
  Search](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search.html)
  enabled on the account — an account-wide, one-time setting, not scoped to
  this deployment's own resources. This Terraform does not bootstrap it, so
  it must already be enabled some other way (another stack, the console, or
  a teammate) before traces will show up. If it isn't, the collector logs
  `Message=The OTLP API is supported with CloudWatch Logs as a Trace Segment
  Destination` (per AWS's troubleshooting docs) and traces are dropped.

This is intentionally a single-instance, no-HA setup: it's meant for demoing
the telemetry pipeline, not for production traffic.

Terraform provisions the AWS resources (VPC, EC2 instance, an Elastic IP for
a stable public address, security group, IAM role, CloudWatch log groups);
Ansible installs Docker on the instance and runs `docker compose up -d`
against a synced copy of the repo, after templating AWS exporters into the
collector's existing customization seam
(`src/otel-collector/otelcol-config-extras.yml`) — no upstream files are
modified. After pulling the public Compose images, Ansible builds the `ad`
image locally from that synced checkout because this deployment's gRPC health
check requires the probe added by `src/ad/Dockerfile`, which is not yet present
in the public `latest-ad` image. A small Ansible-deployed compose override additionally publishes
`frontend-proxy` on port 80 (alongside its usual 8080), so the app is
reachable on the standard HTTP port at a fixed IP that survives instance
replacement.

## Prerequisites

- An AWS account and credentials available to Terraform (e.g. `aws configure`,
  or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html)
  (includes the `ansible.posix` collection used for `synchronize`)
- An SSH client (used by Ansible, and by `make ssh`, to reach the instance)
- To use `make ssm`: the AWS CLI plus its Session Manager plugin

Both `terraform` and `ansible` can be installed via Homebrew:
`brew tap hashicorp/tap && brew install hashicorp/tap/terraform ansible`.

**Installing the Session Manager plugin.** `brew install --cask
session-manager-plugin` needs a GUI `sudo` installer prompt, which fails in
headless/CI/agent shells ("sudo: a terminal is required"). If you hit that,
install the plugin binary directly, no sudo required:

```bash
curl -sL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o /tmp/sm.zip
unzip -q -o /tmp/sm.zip -d /tmp
mkdir -p ~/bin
cp /tmp/sessionmanager-bundle/bin/session-manager-plugin ~/bin/
chmod +x ~/bin/session-manager-plugin
export PATH="$HOME/bin:$PATH"   # add to your shell profile to persist
```

(Swap the URL's `mac` for `linux` on Linux — see the [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
for other platforms/architectures. The Mac bundle is x86_64; it runs fine
under Rosetta 2 on Apple Silicon.)

## Cost

Running continuously, expect roughly **$120-150/month**, dominated by the
`t3.xlarge` instance (~$121/mo on-demand) plus a 60GB gp3 volume (~$5/mo).
CloudWatch Logs ingestion/storage and X-Ray trace recording add a small
amount on top and mostly stay within the AWS free tier for light demo
traffic. Run `make down` (or stop the instance) when you're not using it.

## Create

```bash
cd deploy/aws/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set `allowed_cidr` to your own IP (find it with
`curl -s https://checkip.amazonaws.com`), e.g. `"203.0.113.4/32"`. This is
required — it scopes SSH (22) and the demo frontend (80 and 8080) to just
you. Also set `owner` to your name or email — it's required and gets tagged
onto every resource, along with `Project`, `Name`, `awsApplication`,
`ManagedBy`, and the deploying commit's `GitRepo`/`GitBranch`/`GitCommit`/
`LastModified` (see the `default_tags` block in `terraform/main.tf`).
Optionally also set `alert_email` to receive downtime alerts (see
[Monitoring and alerts](#monitoring-and-alerts) below) — the alarms
themselves are always created and visible in the console either way; left
unset (the default), no SNS topic/subscription is created, so the alarms
just have nothing wired up to notify. AWS emails the address a
subscription-confirmation link on the first apply, and alerts won't arrive
until that's clicked.

Before applying, you can validate and preview changes:

```bash
make validate   # validate Terraform config locally (no AWS credentials required)
make plan       # show what terraform apply would create/change/destroy
make fmt        # auto-format any Terraform source files you edited
```

```bash
cd deploy/aws
make up
```

This runs `terraform apply` (via `terraform/apply-with-retry.sh` — see
below) to create the VPC/EC2/IAM/CloudWatch resources and write
`ansible/inventory.ini` + a generated SSH key, then runs the Ansible
playbook to install Docker, sync the repo, wire up the AWS exporters, and
start the stack. First run takes a few minutes (instance boot + image
pulls). `up`/`update` apply non-interactively (`-auto-approve`); run `make
plan` first if you want to review changes before applying.

Ansible's first task waits for SSH to actually accept connections
(`wait_for_connection`) and for cloud-init to finish before doing anything
else — `terraform apply` returns as soon as AWS reports the instance
"running", which is well before sshd is actually up, so connecting
immediately would otherwise fail.

Two AWS-side quirks `make up` handles automatically, discovered by running
many full `terraform destroy` → `make up` cycles back to back:

- **An out-of-band VPC endpoint blocks subnet/VPC deletion.** Accounts with
  org-wide GuardDuty runtime monitoring have AWS auto-attach a
  `guardduty-data` interface VPC endpoint (with its own ENI and security
  group) into every new VPC — Terraform doesn't manage it, but it blocks
  `terraform destroy` from ever completing the subnet/VPC teardown. A
  `null_resource` in `terraform/network.tf` deletes any such endpoint and
  its security group at destroy time, before Terraform touches the
  subnet/VPC.
- **CloudWatch log group creation can race with itself.** Re-creating the
  `/otel-demo/*` log groups right after a `terraform destroy` can fail once
  with `ResourceAlreadyExistsException` even on a clean apply — the create
  actually succeeds on AWS's side, but the provider doesn't record it in
  state (looks like an internal request retry racing the real response).
  `terraform/apply-with-retry.sh` detects that specific error, imports
  whatever was actually created, and retries — any other failure is
  surfaced immediately, not silently retried.

```bash
make outputs
```

prints the app URL (`http://<elastic-ip>` — port 80, also reachable on
`:8080`) and the ssh command. The IP is an Elastic IP, so it stays the same
across `make update` even if the underlying instance gets replaced.

## Modify

Edit code or config locally as usual (e.g. change a service, tweak
`src/otel-collector/otelcol-config-extras.yml` — anything under the repo
root gets synced), then:

```bash
make update
```

This re-applies any Terraform variable changes, re-syncs the repo to the
instance, re-renders the AWS exporters config, and runs `docker compose up
-d` again.

If you only changed source code (no bind-mounted config files on services
outside the default recreate list), a faster path skips recreating containers
whose image/env/command didn't change:

```bash
make update-fast
```

This runs the same Terraform apply and Ansible playbook as `update`, but
passes `fast_update=true` to Ansible, which tells it to skip forced container
recreation for services that `docker compose up -d` would leave alone. The
handful of services that bind-mount config files (`otel-collector`, `flagd`,
`flagd-ui`, `product-catalog`) are always recreated regardless. Use plain
`make update` if you changed a bind-mounted config file on a service not in
that list.

To include Kafka/accounting/fraud-detection (`compose.full.yaml`), set
`compose_profile = "full"` in `terraform.tfvars` and run `make update`.

## Destroy

```bash
make down
```

Runs `terraform destroy` — removes the instance, security group, VPC, IAM
role, and CloudWatch log groups. Nothing is left running or billing. Takes
2-3 minutes in accounts with GuardDuty runtime monitoring enabled (see
above) while it waits for AWS to detach GuardDuty's own ENI from the VPC
before the subnet/VPC can be deleted; this is automatic, not a hang.

## Verifying telemetry landed in CloudWatch

- **Traces**: AWS Console → CloudWatch → Traces (or X-Ray → Traces)
- **Logs**: AWS Console → CloudWatch → Log groups → `/otel-demo/logs`
  (application logs via the collector) or `/otel-demo/otelcol` (the
  collector's own self-telemetry)
- **Metrics**: AWS Console → CloudWatch → **Query Studio**, then run a PromQL
  query. `{__name__!=""}` lists everything arriving; the demo's own metrics are
  defined in [`telemetry-schema/metrics/`](../../telemetry-schema/metrics/) and
  appear with dots replaced by underscores, so `demo.ad.requests` is queried as
  `demo_ad_requests`. These will *not* show up under CloudWatch → Metrics,
  which lists only classic namespaces — the OTLP endpoint feeds CloudWatch's
  separate OTel metric store.

## Monitoring and alerts

Two things watch the instance beyond the app's own telemetry, both installed
by Ansible (`roles/cloudwatch_agent`, `roles/service_health`) and provisioned
by Terraform (`terraform/monitoring.tf`, `alerts.tf`):

- **Per-service health, restart counts, and downtime alerts.** A script
  (`roles/service_health/files/check.py`) runs every 60 seconds via a systemd
  timer and checks every container compose.yaml/compose.full.yaml starts, by
  its fixed `container_name`. For most services that means reading Docker's
  own `HEALTHCHECK` status (falling back to `State.Running` for the few
  without one: `cart`, `flagd`, `otel-collector`); for the handful that are
  genuinely HTTP (`frontend`, `frontend-proxy`, `image-provider`, `flagd-ui`,
  `telemetry-docs`, plus `flagd`'s management port) it additionally does a
  real `GET` against the container's own docker-network IP. Both the up/down
  state and Docker's restart count are pushed as OTLP gauges
  (`deploy.service_up`, `deploy.service_restart_count`) straight into the
  otel-collector container's own OTLP receiver — the same one every app
  service sends to — rather than calling a CloudWatch API directly, so they
  ride the collector's existing metrics pipeline out to the same
  `otlphttp`/`sigv4auth` export as everything else, and land in the same OTel
  metric store with the same resource labeling (each service's
  `OTEL_RESOURCE_ATTRIBUTES`, plus whatever `resourcedetection` adds). There's
  no classic-namespace copy.

  A PromQL alarm per service (in `terraform/monitoring.tf`, always created
  and visible in the console regardless of `alert_email`) queries
  `deploy.service_up` for that service and fires once it's been reported
  `0`, *or* stopped being reported at all (`absent_over_time` over a
  3-minute window, tolerating one missed push), continuously for 5 minutes;
  it also recovers back to OK the same way. If `alert_email` is set, firing
  and recovering both additionally email that address via SNS — otherwise
  the alarms just have no action wired up, same as the EC2
  instance-status-check alarm below. Folding "stopped reporting" into the query like that matters
  because a PromQL alarm's query simply stops returning a series once
  nothing is reporting it, which alone reads as *recovering*, not breaching
  — unlike a classic alarm's `treat_missing_data = "breaching"`. With the
  `absent_over_time` branch, that now also catches the check script or the
  otel-collector container itself going down, not just an explicit unhealthy
  report — `alerts.tf`'s instance-status-check alarm (EC2
  `StatusCheckFailed`) remains a coarser backstop on top for "the whole
  instance is dead." This needs `hashicorp/aws` >= 6.42 (see `versions.tf`),
  the first provider version with PromQL-alarm support
  (`evaluation_criteria`/`promql_criteria`) — classic
  `aws_cloudwatch_metric_alarm` namespace/dimensions can't read the OTel
  metric store at all. Check your inbox (including spam) for the SNS
  subscription-confirmation email after the first `make up`/`make update`
  with `alert_email` set — alerts are silently dropped until it's confirmed.
- **Box infrastructure.** The [CloudWatch
  agent](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Agent-on-EC2-Instance.html)
  runs on the host directly (not in Docker) collecting CPU, memory, disk,
  filesystem, load, and network metrics via its OTel-native `hostmetrics`
  receiver, exported the same way the app's own telemetry is — `otlphttp` +
  `sigv4auth` straight to CloudWatch's OTLP metrics endpoint (see
  `roles/cloudwatch_agent/templates/otel-extra.yaml.j2`) — so it lands in the
  same OTel metric store, queryable with PromQL in Query Studio. Per-service
  metrics don't go through the CloudWatch agent at all (see above); its
  supported component set has no HTTP-check or Docker-stats receiver anyway,
  which is why those checks live in the service-health script instead.

`deploy.service_restart_count` is pushed but not wired to its own alarm —
query it in Query Studio, or add a second PromQL alarm for it the same way
`service_down` is defined if you want paging on repeated restarts too.

The collector also turns every metrics-exporter partial-success response into
the OTLP counter `demo.collector.exporter.dropped_metric_data_points`. Each
delta is the backend's `dropped_data_points` value, rather than a count of log
events, so summing it over a time window quantifies the actual telemetry
coverage loss. It follows the existing metrics pipeline into CloudWatch's OTel
metric store and is queried in Query Studio like the other OTLP metrics; no
classic CloudWatch namespace or log metric filter is involved.

## Operating it

```bash
make status                    # state of every container on the instance
make logs SERVICE=cart         # tail one service's container logs
make shell SERVICE=cart        # open a shell inside a running container
make restart                   # restart every container without re-provisioning
```

`make restart` runs `docker compose restart` on the instance over SSH — it
bounces every running container without pulling new images, re-syncing the
repo, or re-running Ansible. Use it when a service is wedged and needs a
kick, not when you want to pick up a code or config change (use `make update`
or `make update-fast` for that).

These are the same three targets the sibling [`../aws-ecs/`](../aws-ecs/)
deployment exposes, so the two stacks are driven the same way. Here they run
`docker compose ps` / `logs` / `exec` on the instance over the
Terraform-generated SSH key, using the same compose file set Ansible started
the stack with — so they see the whole project, not just `compose.yaml`.
`SERVICE` defaults to `frontend-proxy`; `EXEC_SHELL` (default `/bin/sh`)
overrides the shell for containers that ship a different one.

Container logs live on the instance under Docker's `json-file` driver, not in
CloudWatch — `/otel-demo/logs` holds only what the collector forwards through
its `otlphttp` logs exporter. `make logs` is the way to see raw stdout.

```bash
make otelcol-config             # print the otel-collector's fully resolved/merged config
```

This is the same target the sibling [`../aws-ecs/`](../aws-ecs/) deployment
exposes. It runs the collector's own `print-config` subcommand with the same
`--config` layers (and feature gate) the container is actually launched with,
so what it prints is the config after `otelcol-config.yml` and
`otelcol-config-extras.yml` are deep-merged — not either file on its own.
Useful for confirming an Ansible-rendered change (like the AWS exporters)
actually made it into the running container.

## Logging into the instance

`make shell` gets you into a container; these get you onto the host itself:

```bash
make ssh   # SSH, using the Terraform-generated key -- what Ansible itself uses
make ssm   # AWS Systems Manager Session Manager -- no SSH key or open port needed
```

**`make ssh`** needs `allowed_cidr` to actually cover the IP you're
connecting from *right now*. If you're on a network with a rotating/pooled
outbound IP (common in some sandboxed or corporate-proxied environments —
check by running `curl -s https://checkip.amazonaws.com` a couple of times
a minute apart and seeing if it changes), a single `/32` won't reliably
work. Widen `allowed_cidr` to a range that actually covers your egress pool,
run `make update` to apply it, and re-check with `curl checkip.amazonaws.com`
if SSH still times out. Avoid `0.0.0.0/0` except as a last resort for a
one-off verification, and narrow it back down afterward.

If instead you get **`Permission denied (publickey,gssapi-keyex,gssapi-with-mic)`**
with a key you're sure is correct (right file, right fingerprint, present in
`authorized_keys` on the box), it's likely not the key at all: some AL2023
AMIs wire sshd's `AuthorizedKeysCommand` to EC2 Instance Connect
(`/opt/aws/bin/eic_run_authorized_keys`), and if that command fails (check
`journalctl -u sshd` for `AuthorizedKeysCommand ... failed, status 255`),
OpenSSH treats it as fatal for the whole auth attempt — blocking the static
`authorized_keys` file too, not just EIC's own flow. The `docker` Ansible
role now disables this proactively (comments out
`AuthorizedKeysCommand`/`AuthorizedKeysCommandUser` and restarts sshd) on
every `make up`/`make update`, so a fresh deploy shouldn't hit this. If you
still do (e.g. on an instance provisioned before this fix), get in via
`make ssm` or `aws ssm send-command` (see below) and disable it manually:

```bash
sudo sed -i -E 's/^(AuthorizedKeysCommand.*)$/#\1/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart sshd
```

**`make ssm`** opens an interactive shell through the AWS API instead of the
security group, so it doesn't depend on `allowed_cidr` at all, and every
session is logged in CloudTrail. It needs the instance's IAM role (already
attached — `AmazonSSMManagedInstanceCore`) and the Session Manager plugin
locally (see Prerequisites). Some AWS accounts restrict the *interactive*
`ssm:StartSession` action via SCP or permission boundary even when other SSM
actions are allowed — if `make ssm` fails with a 403
("Server authentication failed") while `aws ssm describe-instance-information`
works fine, that's almost always an intentional org-level control, not a
bug; check with whoever administers the account rather than trying to route
around it. In that case, fall back to `make ssh`, or run one-off commands
non-interactively via `aws ssm send-command` (document
`AWS-RunShellScript`), which is commonly still allowed and is how the
`docker`/`otel_demo` Ansible roles' checks were verified against this stack.

**Recovering SSH access without a working key.** If the local
`ansible/otel-demo-ssh.pem` is ever lost or out of sync with the instance
(e.g. state drift, a botched `terraform apply`), and `make ssm` works, you
can bootstrap SSH back without recreating the instance: generate a fresh
local keypair, then use `aws ssm send-command` to append its public half to
`/home/ec2-user/.ssh/authorized_keys`:

```bash
ssh-keygen -t ed25519 -f ./ansible/otel-demo-ssh.pem -N ""
PUBKEY=$(cat ./ansible/otel-demo-ssh.pem.pub)
aws ssm send-command --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters "{\"commands\":[\"mkdir -p /home/ec2-user/.ssh\",\"echo '$PUBKEY' >> /home/ec2-user/.ssh/authorized_keys\",\"chown -R ec2-user:ec2-user /home/ec2-user/.ssh\",\"chmod 700 /home/ec2-user/.ssh\",\"chmod 600 /home/ec2-user/.ssh/authorized_keys\"]}"
```

Treat this as a stopgap: it gets you back in, but the Terraform-managed
`aws_key_pair` and the key actually trusted on the box are now out of sync.
Reconcile them properly (`terraform import`/`-replace` as needed, then push
the resulting key the same way) rather than leaving it drifted long-term.

## Troubleshooting

```bash
make status                        # which containers are up, and which are restarting
make logs SERVICE=otel-collector   # then read the logs of whichever one is not
```

Or drive compose by hand, after `make ssh` (or `make ssm`), from
`/opt/otel-demo` on the instance:

```bash
docker compose -f compose.yaml -f compose.aws-override.yml ps
docker compose -f compose.yaml -f compose.aws-override.yml logs otel-collector
```

**Browser gives `ERR_CONNECTION_REFUSED` even though SSH/SSM works.**
`terraform apply` and the Ansible run are two separate steps — `make up`
chains them, but if you ever ran `terraform apply` (or
`apply-with-retry.sh`) on its own, e.g. while debugging, the instance
exists and SSH/SSM work fine (that only needs the EC2 instance + its key),
but Docker was never installed and nothing is listening on 80/8080 yet.
Confirm with `which docker` over SSH — if that's empty, provisioning never
ran. Fix: `cd deploy/aws/ansible && ansible-playbook -i inventory.ini
site.yml` (or just `make update`), which is idempotent and safe to re-run.

If the collector isn't exporting, check its logs for AWS SDK/credential
errors — it authenticates via the EC2 instance's IAM role, so there are no
credentials to configure by hand.
