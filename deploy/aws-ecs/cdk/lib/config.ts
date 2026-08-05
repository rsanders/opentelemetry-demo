// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import * as fs from 'fs';
import * as path from 'path';

export interface DemoConfig {
  /** CIDR allowed to reach the load balancer on 80/8080. */
  allowedCidr: string;
  region: string;
  /** Prefix for resource names, log groups, and the Cloud Map namespace. */
  projectName: string;
  /** Registry/repository the demo service images are pulled from. */
  imageName: string;
  /** Tag prefix, e.g. "latest" pulls "<imageName>:latest-cart". */
  demoVersion: string;
  cpuArchitecture: 'X86_64' | 'ARM64';
  loadGeneratorVus: number;
  logRetentionDays: number;
}

const DEFAULTS: DemoConfig = {
  allowedCidr: '162.200.0.0/16',
  region: 'us-east-1',
  projectName: 'otel-demo-ecs',
  imageName: 'ghcr.io/open-telemetry/demo',
  demoVersion: 'latest',
  cpuArchitecture: 'X86_64',
  loadGeneratorVus: 5,
  logRetentionDays: 14,
};

const CIDR_RE = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;

/**
 * Reads config.json (gitignored, copied from config.example.json) if present
 * and layers it over the defaults. This mirrors terraform.tfvars in the
 * sibling deploy/aws stack.
 */
export function loadConfig(cdkDir: string): DemoConfig {
  const file = path.join(cdkDir, 'config.json');
  let fromFile: Partial<DemoConfig> = {};

  if (fs.existsSync(file)) {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, unknown>;
    delete parsed._comment;
    fromFile = parsed as Partial<DemoConfig>;
  }

  const config: DemoConfig = { ...DEFAULTS, ...fromFile };

  if (!CIDR_RE.test(config.allowedCidr)) {
    throw new Error(
      `allowedCidr must be a valid IPv4 CIDR block, e.g. 203.0.113.4/32 (got "${config.allowedCidr}"). ` +
        `Set it in ${file}.`,
    );
  }
  if (config.cpuArchitecture !== 'X86_64' && config.cpuArchitecture !== 'ARM64') {
    throw new Error(
      `cpuArchitecture must be "X86_64" or "ARM64" (got "${config.cpuArchitecture}").`,
    );
  }

  return config;
}