# OpenTelemetry Demo on ECS Fargate (us-east-1)

Deploys the demo's core services (`compose.yaml`) as **one ECS Fargate service
per compose service**, and forwards everything the `otel-collector` service
sees into CloudWatch:

- **Metrics** → CloudWatch Metrics, via the `awsemf` exporter (namespace `OtelDemo`)
- **Logs** → CloudWatch Logs, via the `awscloudwatchlogs` exporter
- **Traces** → AWS X-Ray, via the `awsxray` exporter (visible in the CloudWatch
  console under Traces / ServiceLens — CloudWatch itself has no trace store)

Everything is defined in AWS CDK (TypeScript) under [`cdk/`](cdk/) — there is
no Terraform and no Ansible here. One `cdk deploy` creates the VPC, ECS
cluster, Cloud Map namespace, load balancer, IAM roles, log groups, and all 19
task definitions and services.

Like its sibling, this is intentionally a no-HA setup — single AZ, one task per
service, no autoscaling. It exists to demo the telemetry pipeline, not to serve
production traffic.

> **Status: not yet deployed.** Everything here is validated by `make validate`
> (`tsc --noEmit` plus `cdk synth`) against the generated CloudFormation
> template. Unlike [`../aws/`](../aws/), it has not been run against a live AWS
> account, so treat the first `make up` as the real test. See "Known
> limitations" for the parts most likely to need adjustment.

## How this compares to `../aws/`

This is the ECS counterpart to [`../aws/`](../aws/), which runs the same demo
on a single EC2 instance with Docker Compose. The two are independent: every
AWS resource here is named `otel-demo-ecs*` (cluster, load balancer, log
groups, IAM roles, Cloud Map namespace, CloudFormation stack), so both can be
deployed into the same account at the same time without colliding.

|                           | [`../aws/`](../aws/)                                 | `aws-ecs/` (this one)                              |
| ------------------------- | ---------------------------------------------------- | -------------------------------------------------- |
| **Cost/month**            | ~$120-150                                            | **~$270-310** (~$250 Fargate + ~$18 NLB)           |
| Compute                   | 1 × `t3.xlarge` EC2, all 20 containers               | 19 Fargate tasks, one service per compose service  |
| Defined in                | Terraform + Ansible                                  | AWS CDK (TypeScript), single stack                 |
| Deploy mechanism          | `terraform apply`, then `docker compose up` over SSH | `cdk deploy`                                       |
| Runs your local code      | Yes — rsyncs the repo checkout                       | No — pulls published `ghcr.io` images              |
| Service discovery         | Docker bridge network, bare container names          | Cloud Map private DNS, `<svc>.otel-demo-ecs.local` |
| Config files              | Bind-mounted from the repo                           | Seeded into a task volume by an init container     |
| Public address            | Elastic IP on the instance                           | Elastic IP on a network load balancer              |
| Shell access              | `make ssh` / `make ssm`                              | `make shell` (ECS Exec)                            |
| Host/Docker metrics       | `host_metrics` + `docker_stats` receivers            | Dropped — Fargate exposes neither                  |
| Blast radius of a restart | Whole host                                           | One service                                        |

The headline trade: you pay about twice as much for per-service isolation —
independent task definitions, restarts, scaling, and log groups — and give up
running your local working copy. Both sections below ("Cost", "How this differs
from Compose") go into why.

## Prerequisites

- An AWS account and credentials available to the CDK (e.g. `aws configure`, or
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars)
- Node.js 20 or newer (`brew install node`) — the CDK CLI is installed locally
  by `make install`, so there is nothing to install globally
- The AWS CLI, plus its Session Manager plugin if you want `make shell`

No Docker is needed. All service images are pulled from the demo's public
`ghcr.io` packages, and the handful of config files that Compose bind-mounts are
written into each task at startup instead of baked into new images (see
"How config files get in" below) — so there is no image to build and no ECR
repository to push to.

## Cost

Running continuously, expect roughly **$270-310/month**: about 6.9 vCPU and
13.5 GB of Fargate across the 19 tasks (~$250/mo), plus ~$18/mo for the network
load balancer, plus CloudWatch Logs ingestion and X-Ray trace recording.

That is roughly **twice** the EC2 deployment's ~$120-150/mo. Fargate bills each
task's reserved CPU and memory independently, and Fargate's smallest task size
(0.25 vCPU / 0.5 GB, ~$9/mo) is more than most of these services actually need —
on one EC2 instance they share a single host's slack instead. You are paying for
per-service isolation, not for more capacity. Run `make down` when you are not
using it.

Setting `"cpuArchitecture": "ARM64"` in `cdk/config.json` cuts the Fargate bill
by about 20%. All the demo images are published for both `linux/amd64` and
`linux/arm64`; `X86_64` is the default only because it is the more-tested path.

## Create

```bash
cd deploy/aws-ecs/cdk
cp config.example.json config.json
```

Edit `config.json` and set `allowedCidr` to your own IP (find it with `curl -s
https://checkip.amazonaws.com`), e.g. `"203.0.113.4/32"`. This scopes the demo
frontend (80 and 8080) to just you.

```bash
cd deploy/aws-ecs
make up
```

`make up` installs the CDK app's dependencies, runs `cdk bootstrap` (idempotent;
needed once per account/region), and then `cdk deploy`. First run takes 10-15
minutes: CloudFormation creates the network and cluster, then brings the
services up in four waves (see "Startup ordering" below).

```bash
make outputs
```

prints the app URL (`http://<elastic-ip>` — port 80, also reachable on `:8080`),
the static IP, and the cluster name. The IP is an Elastic IP attached to the
load balancer, so it stays the same across `make update` and across task
replacement.

## Modify

Change `cdk/config.json` or anything under `cdk/`, then:

```bash
make update     # cdk deploy
make plan       # cdk diff, if you want to see the change first
```

Unlike the EC2 deployment, this does **not** sync your local repo checkout. The
services run the published `ghcr.io` images, so local edits to `src/` have no
effect. What *is* read from the repo at synth time is the top-level `.env` file
(ports, image tags, passwords) and the three config files listed below — so
bumping an image version in `.env` and running `make update` does roll out.

To run your own builds instead, push images somewhere ECS can pull them and
point `imageName`/`demoVersion` in `config.json` at that repository.

## Destroy

```bash
make down
```

Runs `cdk destroy`, which deletes the CloudFormation stack: all 19 services,
the cluster, VPC, load balancer, Elastic IP, IAM roles, and log groups. Nothing
is left running or billing. The CDK bootstrap stack (`CDKToolkit`) is
deliberately left alone — it is shared by every CDK app in the account.

## Verifying telemetry landed in CloudWatch

- **Traces**: AWS Console → CloudWatch → Traces (or X-Ray → Traces)
- **Logs**: AWS Console → CloudWatch → Log groups → `/otel-demo-ecs/logs`
  (application logs via the collector) and `/otel-demo-ecs/otelcol` (EMF metric
  log lines)
- **Metrics**: AWS Console → CloudWatch → Metrics → custom namespace `OtelDemo`

Each service's raw container stdout also goes to its own group,
`/otel-demo-ecs/<service>`, via the `awslogs` driver — that is what `make logs`
tails.

## Operating it

```bash
make status                    # running/desired task count per service
make logs SERVICE=cart         # tail one service's container logs
make shell SERVICE=cart        # open a shell inside a running container
```

`make shell` uses [ECS
Exec](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html),
which is the Fargate equivalent of the EC2 deployment's `make ssm`: a shell
opened through the AWS API rather than an inbound port, with every session
logged in CloudTrail. It needs the Session Manager plugin for the AWS CLI
locally — see [`../aws/README.md`](../aws/README.md#prerequisites) for how to
install it without a GUI sudo prompt.

`make ssh` and `make ssm` are aliases for `make shell`, kept so the target names
line up with the sibling stack. There is no host to SSH into here — every
service is a Fargate task.

The `flagd` service carries two containers, `flagd` and `flagd-ui`; reach the
second one with `make shell SERVICE=flagd CONTAINER=flagd-ui`.

## How this differs from Compose

Four things in `compose.yaml` have no direct Fargate equivalent. Each is
handled explicitly rather than dropped silently.

**Service discovery is Cloud Map, not a Docker bridge network.** `awsvpc` tasks
get their own ENI and cannot resolve each other by bare container name, so every
service registers an A record in a private DNS namespace and the compose
`*_ADDR`/`*_HOST` variables are rebuilt against those FQDNs (`cart` →
`cart.otel-demo-ecs.local`). Two places in the collector's base config hardcode
short Compose hostnames (`valkey-cart:6379`, and the `ad` Prometheus scrape
target) rather than reading them from the environment; those are redirected in
`cdk/files/otelcol-config-extras-aws.yml`.

**How config files get in.** Compose bind-mounts four files from the repo:
`otel-config.yml` into `product-catalog`, `src/flagd/demo.flagd.json` into
`flagd` and `flagd-ui`, `src/postgresql/init.sql` into `astronomy-db`, and the
collector's own config. Fargate has no host filesystem to mount from. Rather
than build four derived images, each of those tasks gets a `config-seed` init
container: the file contents are embedded as base64 at synth time, the init
container writes them into a volume shared with the task's other containers,
and the real container starts only after it exits successfully. That is what
keeps `cdk deploy` free of any local Docker build.

Because `flagd` and `flagd-ui` share that flag-config file *and write to it*
from the UI, they are the one place where two compose services become two
containers in a single task — a task-scoped volume is the only way for two
Fargate containers to share a writable directory. They are still separate
containers with separate logs; they just share an IP, so `flagd-ui` is reached
at `flagd.otel-demo-ecs.local:4000`.

**Two collector receivers are dropped.** `docker_stats` needs a Docker socket
and `host_metrics` needs the host filesystem at `/hostfs`; Fargate offers
neither. The metrics pipeline is redefined without them in the extras file, and
the `resourcedetection` processor's `docker` detector is swapped for `ecs`,
which reads the task metadata endpoint and adds `aws.ecs.*` resource
attributes. Everything else — `otlp`, `postgresql`, `redis`, `nginx`,
`http_check`, `prometheus/ad`, `span_metrics` — carries over unchanged.

**Startup ordering is coarse.** Compose's per-service `depends_on` with
`condition: service_healthy` has no ECS equivalent; ECS starts every service at
once and lets the ones whose dependencies are still booting crash-loop until
they settle. To keep a first `make up` from looking like a broken deploy, the
services are created in four waves (`STARTUP_TIERS` in `cdk/lib/services.ts`):
backing services first (collector, flagd, valkey, postgres), then the business
services, then `frontend`, then `frontend-proxy` and the load generator. Within
a wave there is no ordering, and the compose health checks are carried over
as-is so ECS still waits for each container to report healthy.

## Design choices

**One ECS service per compose service, not one task with 20 containers.** The
point of the exercise is per-service isolation: independent task definitions,
independent scaling, independent restarts, independent log groups. Packing
everything into one task would just be the EC2 deployment with extra steps.

**Public subnets and public task IPs, no NAT gateway.** Tasks pull images from
`ghcr.io` and talk to the CloudWatch/X-Ray APIs, both of which need egress. A
NAT gateway would add ~$32/mo; VPC endpoints for ECR/S3/Logs/X-Ray would add
several interface-endpoint charges and still not cover `ghcr.io`. What keeps
the tasks unreachable is the security group — inbound is allowed only from the
load balancer and from the tasks themselves — not the subnet they sit in.

**A network load balancer with an Elastic IP, not an ALB.** Fargate task IPs
are dynamic and cannot take an Elastic IP, so reaching the demo at a stable
address needs a load balancer either way. An ALB gives a stable DNS *name*
backed by rotating IPs; an NLB accepts an Elastic IP and gives a genuinely
static one, matching what the EC2 deployment gets from an EIP on the instance.
Single AZ, so there is exactly one such IP and no cross-AZ data charges.

**Ports, image tags, and passwords are read from the repo's `.env`.** The CDK
app parses the same `.env` Docker Compose reads (`cdk/lib/repo-env.ts`) rather
than restating those values in TypeScript, so an upstream bump to a port or a
dependent image version flows through instead of quietly drifting. Only the
things that genuinely differ on ECS — hostnames, resource sizing, the AWS
exporters — are written out here.

**Least-privilege IAM, no static credentials.** The collector authenticates
through its ECS task role via the default AWS SDK credential chain; there is no
access key to generate or rotate. Its role is scoped to exactly
`logs:CreateLogGroup/CreateLogStream/PutLogEvents/DescribeLogStreams` on the two
demo log groups, `cloudwatch:PutMetricData`, and
`xray:PutTraceSegments/PutTelemetryRecords`. The other 18 services get only the
ECS Exec permissions needed by `make shell`.

**AWS exporters live in the collector's existing customization seam.** The
collector runs `--config=otelcol-config.yml --config=otelcol-config-extras.yml`,
exactly as it does under Compose. Both files are seeded into the task; the
second is `cdk/files/otelcol-config-extras-aws.yml`. Nothing under `src/` is
modified, so a `git diff` against upstream shows no changes outside `deploy/`.

**Core profile only.** `compose.full.yaml` (Kafka, accounting, fraud-detection)
and `compose.observability.yaml` (Jaeger, Prometheus, OpenSearch, Grafana) are
not deployed. The observability stack would be redundant with CloudWatch and
X-Ray as the backend; Kafka on Fargate without persistent storage is a
different problem than the one this deployment is demonstrating.

## Known limitations

- **Not yet exercised against a live account.** The riskiest parts, in rough
  order: whether every service's Compose health check still passes under ECS's
  slightly different execution, whether the four-wave startup ordering is
  actually enough for `checkout` and `cart` to come up cleanly, and whether the
  collector starts with the `ecs` resource detector and the trimmed metrics
  pipeline. All three surface immediately in `make status` and `make logs`.
- **No persistent storage.** `astronomy-db` and `valkey-cart` keep their data in
  the task's ephemeral storage. If a task is replaced, Postgres re-runs
  `init.sql` from scratch and the carts are empty. Adding EFS would fix this;
  it is deliberately left out as unnecessary for a demo.
- **`read_only: true` / `tmpfs` are not applied.** Compose runs `checkout`,
  `product-catalog`, and `shipping` with a read-only root filesystem plus a
  tmpfs at `/tmp`. Fargate does not support `tmpfs` mounts, so the pairing is
  dropped rather than half-applied.
- **A rolling update briefly drops the service.** With one task per service and
  `minHealthyPercent: 0`, ECS stops the old task before starting the new one
  instead of requiring double capacity.
- **A failed deploy stops rather than rolls back.** The deployment circuit
  breaker is enabled (so a broken service fails in minutes rather than the three
  hours ECS otherwise waits) but rollback is off, because on a first `make up`
  there is no previous task definition to roll back to — and leaving the broken
  service in place is what makes `make logs SERVICE=<name>` useful.

## Troubleshooting

```bash
make status                       # which services are short of their desired count
make logs SERVICE=otel-collector  # then read the logs of whichever one is
```

**Browser gives `ERR_CONNECTION_REFUSED`.** Check `allowedCidr` in
`cdk/config.json` still covers the IP you are connecting from right now
(`curl -s https://checkip.amazonaws.com`); on a network with a rotating
outbound IP a single `/32` will not hold. Widen it and run `make update`.

**A service sits at `0/1`.** Read its logs. The usual cause on a first deploy
is a dependency that has not finished starting, which resolves itself within a
few minutes; if it does not, the logs will show what it is actually failing to
reach.

**The collector logs AWS SDK or credential errors.** It authenticates via its
ECS task role, so there is nothing to configure by hand — this points at the
task role's policy or at the region, both in `cdk/lib/otel-demo-ecs-stack.ts`.
