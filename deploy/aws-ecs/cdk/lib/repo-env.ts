// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import * as fs from 'fs';
import * as path from 'path';

/** Repo root, from deploy/aws-ecs/cdk/lib. */
export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..', '..');

/** deploy/aws-ecs/cdk */
export const CDK_DIR = path.resolve(__dirname, '..');

// KEY=value, ignoring blank lines and comments. Values may reference earlier
// keys as ${OTHER_KEY}, and may carry a trailing whitespace-delimited comment.
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
const TRAILING_COMMENT = /\s+#.*$/;
const REFERENCE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g;

/**
 * Reads the repo's top-level .env, the same file Docker Compose reads, and
 * resolves its ${VAR} references.
 *
 * Ports, image tags, and passwords are taken from there rather than restated
 * in TypeScript, so an upstream bump to .env flows into this deployment
 * instead of silently drifting from it.
 */
export function loadRepoEnv(): Record<string, string> {
  const raw: Record<string, string> = {};

  for (const line of fs.readFileSync(path.join(REPO_ROOT, '.env'), 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) continue;

    const match = ASSIGNMENT.exec(trimmed);
    if (match) raw[match[1]] = match[2].replace(TRAILING_COMMENT, '').trim();
  }

  const resolved: Record<string, string> = {};
  const resolving = new Set<string>();

  const resolve = (key: string): string => {
    if (key in resolved) return resolved[key];
    if (resolving.has(key)) throw new Error(`Circular reference to \${${key}} in .env`);
    resolving.add(key);

    const value = (raw[key] ?? '').replace(REFERENCE, (_, ref: string) =>
      ref in raw ? resolve(ref) : '',
    );

    resolving.delete(key);
    resolved[key] = value;
    return value;
  };

  for (const key of Object.keys(raw)) resolve(key);
  return resolved;
}

export function requireEnv(env: Record<string, string>, key: string): string {
  const value = env[key];
  if (!value) throw new Error(`Expected ${key} to be set in the repo's .env file.`);
  return value;
}