#!/usr/bin/env node
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import * as cdk from 'aws-cdk-lib';

import { loadConfig } from '../lib/config';
import { CDK_DIR } from '../lib/repo-env';
import { OtelDemoEcsStack } from '../lib/otel-demo-ecs-stack';

const config = loadConfig(CDK_DIR);
const app = new cdk.App();

new OtelDemoEcsStack(app, 'OtelDemoEcs', {
  config,
  stackName: config.projectName,
  description: 'OpenTelemetry Demo on ECS Fargate, exporting telemetry to CloudWatch and X-Ray.',
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: config.region,
  },
  tags: {
    Project: config.projectName,
    ManagedBy: 'cdk',
  },
});
