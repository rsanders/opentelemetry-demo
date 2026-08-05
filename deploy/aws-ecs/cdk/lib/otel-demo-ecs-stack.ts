// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import * as fs from 'fs';

import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as servicediscovery from 'aws-cdk-lib/aws-servicediscovery';
import { Construct } from 'constructs';

import { DemoConfig } from './config';
import { STARTUP_TIERS, buildCatalog } from './services';

/**
 * Writes the seed files into the task's shared volume. Content is embedded as
 * base64 at synth time, which keeps `cdk deploy` free of any local container
 * build or image push.
 */
const SEED_IMAGE = 'public.ecr.aws/docker/library/busybox:1.37';
const SEED_MOUNT = '/seed';
const SEED_VOLUME = 'config';

export interface OtelDemoEcsStackProps extends StackProps {
  config: DemoConfig;
}

export class OtelDemoEcsStack extends Stack {
  constructor(scope: Construct, id: string, props: OtelDemoEcsStackProps) {
    super(scope, id, props);

    const { config } = props;
    const prefix = config.projectName;
    const retention = toRetentionDays(config.logRetentionDays);

    // ---------------------------------------------------------------- network
    //
    // Public subnets with public task IPs, and no NAT gateway: tasks pull
    // their images straight from ghcr.io and reach the AWS APIs directly. A
    // NAT gateway would add ~$32/mo and buy nothing here, since the security
    // group -- not a private subnet -- is what keeps the tasks unreachable.
    //
    // One AZ, matching the sibling EC2 deployment's explicitly non-HA design,
    // and so the load balancer can front the demo on a single static IP
    // without paying for cross-AZ traffic.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: 'public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
          mapPublicIpOnLaunch: true,
        },
      ],
    });

    const lbSecurityGroup = new ec2.SecurityGroup(this, 'LoadBalancerSecurityGroup', {
      vpc,
      description: `${prefix} load balancer`,
      allowAllOutbound: true,
    });
    lbSecurityGroup.addIngressRule(
      ec2.Peer.ipv4(config.allowedCidr),
      ec2.Port.tcp(80),
      'Demo frontend on the standard HTTP port',
    );
    lbSecurityGroup.addIngressRule(
      ec2.Peer.ipv4(config.allowedCidr),
      ec2.Port.tcp(8080),
      'Demo frontend on its native Envoy port',
    );

    const serviceSecurityGroup = new ec2.SecurityGroup(this, 'ServiceSecurityGroup', {
      vpc,
      description: `${prefix} Fargate tasks`,
      allowAllOutbound: true,
    });
    serviceSecurityGroup.addIngressRule(
      serviceSecurityGroup,
      ec2.Port.allTraffic(),
      'Service-to-service traffic, the Docker bridge network equivalent',
    );

    // ------------------------------------------------------- public entrypoint
    //
    // An Elastic IP on a network load balancer, rather than an ALB, so the
    // demo keeps the genuinely static address the EC2 deployment has. Fargate
    // task IPs are dynamic and cannot take an EIP, so some load balancer is
    // required either way.
    const eip = new ec2.CfnEIP(this, 'ElasticIp', {
      domain: 'vpc',
      tags: [{ key: 'Name', value: `${prefix}-public-ip` }],
    });
    const publicUrl = `http://${eip.ref}`;

    const subnet = vpc.publicSubnets[0];
    const loadBalancer = new elbv2.NetworkLoadBalancer(this, 'LoadBalancer', {
      loadBalancerName: `${prefix}-nlb`,
      vpc,
      internetFacing: true,
      securityGroups: [lbSecurityGroup],
      vpcSubnets: { subnets: [subnet] },
    });
    // The L2 only exposes plain subnets; attaching the EIP needs subnet
    // mappings, which are mutually exclusive with them.
    const cfnLoadBalancer = loadBalancer.node.defaultChild as elbv2.CfnLoadBalancer;
    cfnLoadBalancer.addPropertyDeletionOverride('Subnets');
    cfnLoadBalancer.addPropertyOverride('SubnetMappings', [
      { SubnetId: subnet.subnetId, AllocationId: eip.attrAllocationId },
    ]);

    // ------------------------------------------------------------------ shared
    const namespaceName = `${prefix}.local`;
    const namespace = new servicediscovery.PrivateDnsNamespace(this, 'Namespace', {
      name: namespaceName,
      vpc,
      description: `Service discovery for ${prefix}`,
    });

    const cluster = new ecs.Cluster(this, 'Cluster', {
      clusterName: prefix,
      vpc,
      enableFargateCapacityProviders: true,
    });

    // The collector's awscloudwatchlogs exporter writes here. Container stdout
    // goes to a per-service group created further down. Metrics need no log
    // group at all -- they go to the CloudWatch OTLP metrics endpoint.
    const appLogGroup = new logs.LogGroup(this, 'AppLogGroup', {
      logGroupName: `/${prefix}/logs`,
      retention,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    const executionRole = new iam.Role(this, 'ExecutionRole', {
      roleName: `${prefix}-task-execution`,
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonECSTaskExecutionRolePolicy'),
      ],
    });

    const cpuArchitecture =
      config.cpuArchitecture === 'ARM64' ? ecs.CpuArchitecture.ARM64 : ecs.CpuArchitecture.X86_64;

    // ---------------------------------------------------------------- services
    const catalog = buildCatalog({
      config,
      namespace: namespaceName,
      publicUrl,
      appLogGroupName: appLogGroup.logGroupName,
    });

    const services = new Map<string, ecs.FargateService>();

    for (const spec of catalog) {
      const id = toPascalCase(spec.name);

      const taskDefinition = new ecs.FargateTaskDefinition(this, `${id}Task`, {
        family: `${prefix}-${spec.name}`,
        cpu: spec.cpu,
        memoryLimitMiB: spec.memoryLimitMiB,
        executionRole,
        runtimePlatform: {
          cpuArchitecture,
          operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
        },
      });

      const logGroup = new logs.LogGroup(this, `${id}LogGroup`, {
        logGroupName: `/${prefix}/${spec.name}`,
        retention,
        removalPolicy: RemovalPolicy.DESTROY,
      });

      let seedContainer: ecs.ContainerDefinition | undefined;
      if (spec.seedFiles?.length) {
        taskDefinition.addVolume({ name: SEED_VOLUME });

        const writes = spec.seedFiles.map((file) => {
          const encoded = fs.readFileSync(file.sourcePath).toString('base64');
          return `echo '${encoded}' | base64 -d > ${SEED_MOUNT}/${file.name}`;
        });
        // World-writable because the consuming containers run as their images'
        // own users, and flagd-ui writes flag edits back into this directory.
        const relax = `chmod 0777 ${SEED_MOUNT} && chmod 0666 ${SEED_MOUNT}/*`;

        seedContainer = taskDefinition.addContainer(`${id}Seed`, {
          containerName: 'config-seed',
          image: ecs.ContainerImage.fromRegistry(SEED_IMAGE),
          essential: false,
          command: ['sh', '-c', ['set -e', ...writes, relax].join('; ')],
          logging: ecs.LogDrivers.awsLogs({
            streamPrefix: 'config-seed',
            logGroup,
          }),
        });
        seedContainer.addMountPoints({
          containerPath: SEED_MOUNT,
          sourceVolume: SEED_VOLUME,
          readOnly: false,
        });
      }

      for (const containerSpec of spec.containers) {
        const container = taskDefinition.addContainer(toPascalCase(containerSpec.name), {
          containerName: containerSpec.name,
          image: ecs.ContainerImage.fromRegistry(containerSpec.image),
          entryPoint: containerSpec.entryPoint,
          command: containerSpec.command,
          user: containerSpec.user,
          environment: containerSpec.environment,
          essential: true,
          logging: ecs.LogDrivers.awsLogs({
            streamPrefix: containerSpec.name,
            logGroup,
          }),
          healthCheck: containerSpec.healthCheck && {
            command: containerSpec.healthCheck.command,
            startPeriod: Duration.seconds(containerSpec.healthCheck.startPeriodSeconds),
            interval: Duration.seconds(containerSpec.healthCheck.intervalSeconds),
            timeout: Duration.seconds(containerSpec.healthCheck.timeoutSeconds),
            retries: containerSpec.healthCheck.retries,
          },
        });

        for (const port of containerSpec.ports) {
          container.addPortMappings({
            containerPort: port,
            protocol: ecs.Protocol.TCP,
          });
        }

        if (containerSpec.configMountPath) {
          container.addMountPoints({
            containerPath: containerSpec.configMountPath,
            sourceVolume: SEED_VOLUME,
            readOnly: false,
          });
        }

        if (seedContainer) {
          container.addContainerDependencies({
            container: seedContainer,
            condition: ecs.ContainerDependencyCondition.SUCCESS,
          });
        }
      }

      const service = new ecs.FargateService(this, `${id}Service`, {
        serviceName: spec.name,
        cluster,
        taskDefinition,
        desiredCount: 1,
        assignPublicIp: true,
        securityGroups: [serviceSecurityGroup],
        vpcSubnets: { subnets: [subnet] },
        // One task per service and no spare capacity to roll through, so
        // replace in place rather than requiring a second task to start first.
        minHealthyPercent: 0,
        maxHealthyPercent: 100,
        // Fail a bad deploy in minutes instead of the three hours ECS
        // otherwise spends waiting. rollback is off because on a first `make
        // up` there is no previous task definition to roll back to, and
        // leaving the broken service in place is what makes `make logs`
        // useful for working out why.
        circuitBreaker: { rollback: false },
        enableExecuteCommand: true,
        cloudMapOptions:
          spec.registerInDns === false
            ? undefined
            : {
                name: spec.name,
                cloudMapNamespace: namespace,
                dnsRecordType: servicediscovery.DnsRecordType.A,
                dnsTtl: Duration.seconds(10),
              },
      });

      services.set(spec.name, service);
    }

    // Compose's depends_on, flattened into waves. See STARTUP_TIERS.
    for (let tier = 1; tier < STARTUP_TIERS.length; tier++) {
      for (const name of STARTUP_TIERS[tier]) {
        const dependent = requireService(services, name);
        for (const earlier of STARTUP_TIERS[tier - 1]) {
          dependent.node.addDependency(requireService(services, earlier));
        }
      }
    }

    // ------------------------------------------------------------------- wiring
    const frontendProxy = requireService(services, 'frontend-proxy');
    const listener = loadBalancer.addListener('HttpListener', { port: 80 });
    listener.addTargets('FrontendProxy', {
      port: 8080,
      targets: [
        frontendProxy.loadBalancerTarget({
          containerName: 'frontend-proxy',
          containerPort: 8080,
        }),
      ],
      healthCheck: { protocol: elbv2.Protocol.TCP },
      deregistrationDelay: Duration.seconds(10),
    });
    const nativeListener = loadBalancer.addListener('EnvoyListener', {
      port: 8080,
    });
    nativeListener.addTargets('FrontendProxyNative', {
      port: 8080,
      targets: [
        frontendProxy.loadBalancerTarget({
          containerName: 'frontend-proxy',
          containerPort: 8080,
        }),
      ],
      healthCheck: { protocol: elbv2.Protocol.TCP },
      deregistrationDelay: Duration.seconds(10),
    });
    serviceSecurityGroup.addIngressRule(
      lbSecurityGroup,
      ec2.Port.tcp(8080),
      'Load balancer to frontend-proxy',
    );

    // The collector authenticates to CloudWatch and X-Ray through its task
    // role, so there is no access key to distribute or rotate. Scoped to
    // exactly the actions its three AWS exporters make.
    const collector = requireService(services, 'otel-collector');
    collector.taskDefinition.addToTaskRolePolicy(
      new iam.PolicyStatement({
        sid: 'CloudWatchLogs',
        actions: [
          'logs:CreateLogGroup',
          'logs:CreateLogStream',
          'logs:PutLogEvents',
          'logs:DescribeLogStreams',
        ],
        resources: [`${appLogGroup.logGroupArn}:*`],
      }),
    );
    collector.taskDefinition.addToTaskRolePolicy(
      new iam.PolicyStatement({
        sid: 'CloudWatchMetrics',
        // What the CloudWatch OTLP metrics endpoint authorizes SigV4-signed
        // requests against; it does not support resource-level restriction.
        actions: ['cloudwatch:PutMetricData'],
        resources: ['*'],
      }),
    );
    collector.taskDefinition.addToTaskRolePolicy(
      new iam.PolicyStatement({
        sid: 'XRay',
        actions: ['xray:PutTraceSegments', 'xray:PutTelemetryRecords'],
        resources: ['*'], // X-Ray write actions do not support resource-level restriction
      }),
    );

    // ------------------------------------------------------------------ outputs
    new CfnOutput(this, 'AppUrl', {
      description: 'URL of the demo frontend (frontend-proxy), on the standard HTTP port.',
      value: publicUrl,
    });
    new CfnOutput(this, 'PublicIp', {
      description: 'Static public (Elastic) IP fronting the demo. Stable across task replacement.',
      value: eip.ref,
    });
    new CfnOutput(this, 'ClusterName', {
      description: 'ECS cluster running the demo services.',
      value: cluster.clusterName,
    });
    new CfnOutput(this, 'NamespaceName', {
      description: 'Cloud Map private DNS namespace the services resolve each other through.',
      value: namespaceName,
    });
    new CfnOutput(this, 'ExecCommandExample', {
      description: 'Open a shell in a running container (needs the Session Manager plugin).',
      value: `make shell SERVICE=cart`,
    });
  }
}

function requireService(
  services: Map<string, ecs.FargateService>,
  name: string,
): ecs.FargateService {
  const service = services.get(name);
  if (!service) throw new Error(`No service named "${name}" in the catalog.`);
  return service;
}

function toRetentionDays(days: number): logs.RetentionDays {
  const match = Object.values(logs.RetentionDays).find((value) => value === days);
  if (match === undefined) {
    throw new Error(
      `logRetentionDays must be a CloudWatch Logs retention period (1, 3, 5, 7, 14, 30, ...); got ${days}.`,
    );
  }
  return match as logs.RetentionDays;
}

function toPascalCase(name: string): string {
  return name
    .split('-')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');
}