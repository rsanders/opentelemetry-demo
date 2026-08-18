# Deploying the OpenTelemetry Demo

This directory holds infrastructure-as-code for running the demo somewhere
other than a developer's laptop. Each subdirectory targets one deployment
environment:

- [`aws/`](aws/) — a single-instance deployment: the whole `compose.yaml`
  stack on one EC2 instance, provisioned with Terraform and Ansible. See
  [`aws/README.md`](aws/README.md).
- [`aws-ecs/`](aws-ecs/) — the same demo with each service in its own ECS
  Fargate task, defined entirely in AWS CDK (TypeScript). See
  [`aws-ecs/README.md`](aws-ecs/README.md).
- [`azure/`](azure/) — a single Ubuntu VM deployment with Terraform and
  Ansible. See [`azure/README.md`](azure/README.md).

Both expose the same `make` interface (`up`, `update`, `down`, `outputs`,
`plan`, `validate`, ...) and name their AWS resources distinctly —
`otel-demo*` versus `otel-demo-ecs*` — so they can coexist in one account.
Pick `aws/` for the cheapest way to get the demo running (~$120-150/mo);
pick `aws-ecs/` to demo per-service isolation on ECS (~$270-310/mo, and see
that README for why the same workload costs twice as much).

See [`TESTING.md`](TESTING.md) for how to build and test the demo itself —
both a one-shot local/CI report and the upstream repo's individual test
suites — before deploying with either of the above.

## Requirements this was built against

- Runs in the user's own AWS account, region `us-east-1`.
- Explicitly a **demo deployment**: no HA, no autoscaling, no multi-AZ —
  optimized for low cost and simplicity over resilience or throughput.
- Collects metrics, logs, and traces through the demo's existing
  `otel-collector` service and forwards them to AWS CloudWatch.
- Infrastructure defined as code, using Terraform or AWS CDK; a
  configuration-management tool (Ansible) is acceptable for in-instance
  setup (installing packages, deploying the app) where that's a better fit
  than cloud-resource IaC.
- Fully repeatable lifecycle: create, modify, and tear down the deployment
  on demand, without manual console steps.

## Design choices and reasoning

The reasoning below is for [`aws/`](aws/), which came first.
[`aws-ecs/`](aws-ecs/) revisits several of these decisions for Fargate and
documents its own in [`aws-ecs/README.md`](aws-ecs/README.md#design-choices).

**EC2 + Docker Compose, not ECS or EKS.** The demo already ships a working
`compose.yaml` describing 22 services. Running it near-unmodified on a
single EC2 instance gets a working deployment with the least new code and
the fewest moving parts to maintain. ECS Fargate means writing out 20+ task
definitions and replacing bind mounts and bridge-network DNS with Cloud Map
and task volumes; EKS adds a managed control-plane bill and Kubernetes
operational overhead. Neither buys anything for a non-HA demo — they'd be
solving problems (rolling deploys, service discovery across many
independently-scaled services) that this workload doesn't have. The
`aws-ecs/` sibling exists to demonstrate that ECS path anyway, at roughly
twice the monthly cost; this one remains the cheap default.

**Terraform for AWS resources, Ansible for the instance.** Terraform owns
everything that's a real cloud resource with a lifecycle worth tracking in
state: VPC, subnet, security group, IAM role, EC2 instance, CloudWatch log
groups. Ansible owns what happens *inside* that instance: installing Docker,
syncing the repo, and running `docker compose up`. Keeping that split
explicit (rather than baking a large shell script into `user_data`, or
reaching for CDK+SSM to do configuration management) means each tool is
used for what it's actually good at, and either half can be re-run
independently — `terraform apply` for infra drift, the Ansible playbook for
app/config changes — without the other.

**Traces go to X-Ray, not raw CloudWatch.** CloudWatch has no native trace
storage; AWS's trace backend is X-Ray, which surfaces in the CloudWatch
console under Traces/ServiceLens. So "forward traces to CloudWatch" is
implemented as the collector's `awsxray` exporter, while logs
(`awscloudwatchlogs`) go to CloudWatch proper. This was confirmed with the
user rather than assumed, since it changes which exporter and IAM
permissions are needed.

**Metrics go through CloudWatch's OTLP endpoint, not the `awsemf` exporter.**
Both deployments post metrics to
`https://monitoring.<region>.amazonaws.com/v1/metrics` with the plain
`otlphttp` exporter, signed by the `sigv4auth` extension, rather than
encoding them as EMF log lines into a CloudWatch log group. This keeps the
metric path ordinary OTLP — no AWS-specific exporter, no log group standing
in for a metric store, and the demo's OTel attributes survive as labels
instead of being flattened into EMF dimensions. The trade is that these
metrics live in CloudWatch's OTel metric store and are queried with PromQL
in Query Studio; they do not appear as a classic namespace under CloudWatch
→ Metrics, so anything built against the old `OtelDemo` namespace needs
rewriting as a PromQL query. The IAM action is `cloudwatch:PutMetricData`
either way.

**AWS exporters live in the collector's existing customization seam.**
`src/otel-collector/otelcol-config-extras.yml` is already an
intentionally-empty stub in the upstream repo, documented as the place to
add exporters for your own backend without touching upstream files. Ansible
templates the AWS exporters into exactly that file, so the deployment adds
config rather than forking it — a `git diff` against upstream shows no
changes outside `deploy/`.

**Deploy `compose.yaml` alone, not the full observability layer.**
`compose.full.yaml` (Kafka, accounting, fraud-detection) is available as an
opt-in `compose_profile = "full"` variable, but `compose.observability.yaml`
(Jaeger, Prometheus, OpenSearch, Grafana) is deliberately left out — with
CloudWatch and X-Ray as the observability backend, standing up a second,
local observability stack alongside them would be redundant.

**Least-privilege IAM, no static credentials.** The collector authenticates
via the EC2 instance's IAM role through the default AWS SDK credential
chain — there's no access key to generate, distribute, or rotate. The
instance role is scoped to exactly `logs:CreateLogGroup/CreateLogStream/
PutLogEvents/DescribeLogStreams`, `cloudwatch:PutMetricData`, and
`xray:PutTraceSegments/PutTelemetryRecords`, rather than attaching broad
AWS-managed policies.

**Network access scoped to one IP, not open to the internet.** Both SSH (22)
and the demo frontend (8080) are restricted to an `allowed_cidr` Terraform
variable — you're forced to set it (e.g. to your own IP) rather than
accidentally exposing a demo checkout flow to the public internet.

**SSM Session Manager as a second way in.** The instance role also carries
`AmazonSSMManagedInstanceCore`, and the `ssm` Ansible role makes sure the
agent is enabled, so `make ssm` can open a shell through the AWS API instead
of SSH — useful if `allowed_cidr` doesn't cover wherever you're connecting
from, and every session is logged in CloudTrail. It's additive: Ansible
still provisions over SSH, this just gives you a second, keyless path in.

**Instance sized for real overhead, not just the compose file's numbers.**
`compose.yaml`'s services declare ~3.2GB of container memory limits in
total, but JVM/Node/Python startup overhead plus Docker/OS overhead need
real headroom, so the default instance type is `t3.xlarge` (4 vCPU/16GB)
rather than something sized to the nominal total.

**A static IP via Elastic IP, not a load balancer.** For a single instance,
an ALB gives a stable *DNS name* backed by rotating IPs, not an actual fixed
IP, and costs ~$16-20/mo plus LCU charges on top of the instance — solving a
problem (traffic distribution across replicas) this deployment doesn't
have. An Elastic IP is free while attached to a running instance, gives a
genuinely static address, and survives instance replacement (`make update`
can replace the EC2 instance without changing the URL you bookmark).

**`make up` is proven idempotent across repeated destroy/apply cycles, not
just tested once.** Two AWS-side quirks only show up on a *fresh* VPC
right after a `terraform destroy`, so they'd be easy to miss testing a
single deploy: an org-wide GuardDuty integration auto-attaches an
unmanaged VPC endpoint (and security group) into every new VPC, which
blocks `terraform destroy` from completing unless cleaned up explicitly;
and CloudWatch log group creation can occasionally race with itself right
after a destroy, failing an otherwise-clean apply with
`ResourceAlreadyExistsException` even though the resource was actually
created. Both are handled automatically (a destroy-time cleanup hook for
the former, a self-healing apply wrapper for the latter) — see
[`aws/README.md`](aws/README.md) for the mechanics. This was verified by
running the full `terraform destroy` → `make up` cycle repeatedly against a
real AWS account, not just read through.

## Instructions for use

See each subdirectory's README for the full walkthrough. Short versions:

```bash
# EC2 + Docker Compose -- see aws/README.md
cd deploy/aws/terraform
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidr to your IP
cd ..
make up       # create infra + deploy the app
make outputs  # print the app URL
make update   # re-sync code/config changes and restart the stack
make down     # tear everything down
```

```bash
# ECS Fargate + CDK -- see aws-ecs/README.md
cd deploy/aws-ecs/cdk
cp config.example.json config.json             # set allowedCidr to your IP
cd ..
make up       # create infra + deploy all 19 services
make outputs  # print the app URL
make update   # re-deploy after a config change
make down     # tear everything down
```
