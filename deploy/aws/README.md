# OpenTelemetry Demo on AWS (us-east-1)

Deploys the demo's core services (`compose.yaml`) onto a single EC2 instance
and forwards everything the `otel-collector` service sees into CloudWatch:

- **Metrics** → CloudWatch Metrics, via the `awsemf` exporter (namespace `OtelDemo`)
- **Logs** → CloudWatch Logs, via the `awscloudwatchlogs` exporter
- **Traces** → AWS X-Ray, via the `awsxray` exporter (visible in the CloudWatch
  console under Traces / ServiceLens — CloudWatch itself has no trace store)

This is intentionally a single-instance, no-HA setup: it's meant for demoing
the telemetry pipeline, not for production traffic.

Terraform provisions the AWS resources (VPC, EC2 instance, security group,
IAM role, CloudWatch log groups); Ansible installs Docker on the instance and
runs `docker compose up -d` against a synced copy of the repo, after
templating AWS exporters into the collector's existing customization seam
(`src/otel-collector/otelcol-config-extras.yml`) — no upstream files are
modified.

## Prerequisites

- An AWS account and credentials available to Terraform (e.g. `aws configure`,
  or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html)
  (includes the `ansible.posix` collection used for `synchronize`)
- An SSH client (used by Ansible to reach the instance)

Both `terraform` and `ansible` can be installed via Homebrew:
`brew tap hashicorp/tap && brew install hashicorp/tap/terraform ansible`.

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
required — it scopes SSH (22) and the demo frontend (8080) to just you.

```bash
cd deploy/aws
make up
```

This runs `terraform apply` (creates the VPC/EC2/IAM/CloudWatch resources and
writes `ansible/inventory.ini` + a generated SSH key), then runs the Ansible
playbook to install Docker, sync the repo, wire up the AWS exporters, and
start the stack. First run takes a few minutes (instance boot + image pulls).

```bash
make outputs
```

prints the app URL (`http://<public-ip>:8080`) and the ssh command.

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

To include Kafka/accounting/fraud-detection (`compose.full.yaml`), set
`compose_profile = "full"` in `terraform.tfvars` and run `make update`.

## Destroy

```bash
make down
```

Runs `terraform destroy` — removes the instance, security group, VPC, IAM
role, and CloudWatch log groups. Nothing is left running or billing.

## Verifying telemetry landed in CloudWatch

- **Traces**: AWS Console → CloudWatch → Traces (or X-Ray → Traces)
- **Logs**: AWS Console → CloudWatch → Log groups → `/otel-demo/logs`
  (application logs) and `/otel-demo/otelcol` (EMF metric log lines)
- **Metrics**: AWS Console → CloudWatch → Metrics → custom namespace `OtelDemo`

## Troubleshooting

```bash
make ssh                                    # SSH into the instance
docker compose -f compose.yaml ps           # from /opt/otel-demo on the instance
docker compose -f compose.yaml logs otel-collector
```

If the collector isn't exporting, check its logs for AWS SDK/credential
errors — it authenticates via the EC2 instance's IAM role, so there are no
credentials to configure by hand.
