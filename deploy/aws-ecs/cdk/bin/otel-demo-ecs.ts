#!/usr/bin/env node
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import * as cdk from 'aws-cdk-lib';

import { loadConfig } from '../lib/config';
import { CDK_DIR, gitInfo } from '../lib/repo-env';
import { OtelDemoEcsStack } from '../lib/otel-demo-ecs-stack';

const config = loadConfig(CDK_DIR);
const git = gitInfo();
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
    Owner: config.owner,
    ManagedBy: 'cdk',
    Name: config.projectName,
    // AWS Resource Groups reads this key for tag-based grouping (the same
    // key AppRegistry/myApplications used to vend before it stopped taking
    // new customers on 2026-07-30) -- a plain static value works just as
    // well since nothing here depends on AppRegistry's ARN-based value.
    // Matches the sibling deploy/aws Terraform stack's main.tf.
    awsApplication: config.projectName,
    // Provenance: which checkout/commit produced this stack. LastModified is
    // the commit's own timestamp rather than the deploy's wall-clock time,
    // so it stays stable across repeat deploys of the same commit instead of
    // diffing every resource's tags on every deploy.
    GitRepo: git.repo,
    GitBranch: git.branch,
    GitCommit: git.commit,
    LastModified: git.commitTimestamp,
  },
});
