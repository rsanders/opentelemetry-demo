// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import * as path from 'path';

import { DemoConfig } from './config';
import { CDK_DIR, REPO_ROOT, loadRepoEnv, requireEnv } from './repo-env';

export interface HealthCheckSpec {
  command: string[];
  startPeriodSeconds: number;
  intervalSeconds: number;
  timeoutSeconds: number;
  retries: number;
}

/** A file written into the task's shared config volume before startup. */
export interface SeedFile {
  /** Absolute path on disk; read at synth time. */
  sourcePath: string;
  /** File name created inside the volume. */
  name: string;
}

export interface ContainerSpec {
  name: string;
  image: string;
  entryPoint?: string[];
  command?: string[];
  user?: string;
  ports: number[];
  environment: Record<string, string>;
  healthCheck?: HealthCheckSpec;
  /** Where the shared config volume is mounted, if this container needs it. */
  configMountPath?: string;
}

export interface ServiceSpec {
  /** ECS service name, and the Cloud Map DNS label other services resolve. */
  name: string;
  cpu: number;
  memoryLimitMiB: number;
  containers: ContainerSpec[];
  seedFiles?: SeedFile[];
  /** False for services nothing dials, e.g. the load generator. */
  registerInDns?: boolean;
}

/**
 * Coarse startup ordering, standing in for compose's per-service depends_on.
 * ECS has no cross-service ordering of its own: without this every service
 * comes up at once and the ones whose dependencies are still booting
 * crash-loop until they settle. Creating them in waves keeps a `make up` from
 * looking like a broken deploy. Order within a wave does not matter.
 */
export const STARTUP_TIERS: string[][] = [
  ['otel-collector', 'flagd', 'valkey-cart', 'astronomy-db'],
  [
    'ad',
    'cart',
    'checkout',
    'currency',
    'email',
    'image-provider',
    'payment',
    'product-catalog',
    'quote',
    'recommendation',
    'shipping',
    'telemetry-docs',
  ],
  ['frontend'],
  ['frontend-proxy', 'load-generator'],
];

export interface CatalogContext {
  config: DemoConfig;
  /** Cloud Map private DNS namespace, e.g. "otel-demo-ecs.local". */
  namespace: string;
  /** Public URL of the demo, used for browser-side telemetry. */
  publicUrl: string;
  appLogGroupName: string;
  otelcolLogGroupName: string;
}

/**
 * Builds the ECS equivalent of the repo's compose.yaml core profile: one
 * Fargate service per compose service, with the same images, ports, and
 * environment.
 *
 * Two differences are structural rather than incidental:
 *
 *   - Compose service names become Cloud Map FQDNs (`cart` -> `cart.<ns>`),
 *     because awsvpc tasks resolve each other through Cloud Map, not a Docker
 *     bridge network.
 *   - Bind-mounted config files become seed files written into a shared task
 *     volume at startup, because Fargate has no host filesystem to mount.
 */
export function buildCatalog(ctx: CatalogContext): ServiceSpec[] {
  const env = loadRepoEnv();
  const ns = ctx.namespace;
  const host = (service: string) => `${service}.${ns}`;

  const imageName = ctx.config.imageName;
  const demoVersion = ctx.config.demoVersion;
  const demoImage = (suffix: string) => `${imageName}:${demoVersion}-${suffix}`;

  const version = requireEnv(env, 'IMAGE_VERSION');
  const namespaceAttr = requireEnv(env, 'OTEL_SERVICE_NAMESPACE');
  const environmentName = requireEnv(env, 'DEPLOYMENT_ENVIRONMENT_NAME');
  const applicationName = requireEnv(env, 'APPLICATION_NAME');
  // aws.application_signals.metric_resource_keys promotes the Application
  // attribute into a metric dimension for Application Signals' Custom
  // Metrics feature -- inert here today, since that feature is wired up for
  // the awsemf exporter and this stack's metrics pipeline uses the native
  // CloudWatch OTLP endpoint instead (otelcol-config-extras-aws.yml).
  // https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AppSignals-CustomMetrics.html
  const resourceAttrs = (criticality: string) =>
    `service.namespace=${namespaceAttr},service.version=${version},service.criticality=${criticality},deployment.environment.name=${environmentName},Application=${applicationName},aws.application_signals.metric_resource_keys=Application`;

  const temporality = requireEnv(env, 'OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE');

  const collectorHost = host('otel-collector');
  const grpcPort = requireEnv(env, 'OTEL_COLLECTOR_PORT_GRPC');
  const httpPort = requireEnv(env, 'OTEL_COLLECTOR_PORT_HTTP');
  const otlpGrpcEndpoint = `http://${collectorHost}:${grpcPort}`;
  const otlpHttpEndpoint = `http://${collectorHost}:${httpPort}`;

  const flagdHost = host('flagd');
  const flagdPort = requireEnv(env, 'FLAGD_PORT');
  const flagdOfrepPort = requireEnv(env, 'FLAGD_OFREP_PORT');
  const flagdManagementPort = requireEnv(env, 'FLAGD_MANAGEMENT_PORT');
  // flagd-ui shares a task with flagd so the two can share a flag-config
  // volume, exactly as they share a bind mount under Compose. One task means
  // one IP, so both are reached at the flagd service's Cloud Map name.
  const flagdUiHost = flagdHost;
  const flagdUiPort = requireEnv(env, 'FLAGD_UI_PORT');

  const adPort = requireEnv(env, 'AD_PORT');
  const adPrometheusPort = requireEnv(env, 'AD_PROMETHEUS_PORT');
  const cartPort = requireEnv(env, 'CART_PORT');
  const checkoutPort = requireEnv(env, 'CHECKOUT_PORT');
  const currencyPort = requireEnv(env, 'CURRENCY_PORT');
  const emailPort = requireEnv(env, 'EMAIL_PORT');
  const frontendPort = requireEnv(env, 'FRONTEND_PORT');
  const envoyPort = requireEnv(env, 'ENVOY_PORT');
  const envoyAdminPort = requireEnv(env, 'ENVOY_ADMIN_PORT');
  const imageProviderPort = requireEnv(env, 'IMAGE_PROVIDER_PORT');
  const paymentPort = requireEnv(env, 'PAYMENT_PORT');
  const productCatalogPort = requireEnv(env, 'PRODUCT_CATALOG_PORT');
  const quotePort = requireEnv(env, 'QUOTE_PORT');
  const recommendationPort = requireEnv(env, 'RECOMMENDATION_PORT');
  const shippingPort = requireEnv(env, 'SHIPPING_PORT');
  const telemetryDocsPort = requireEnv(env, 'TELEMETRY_DOCS_PORT');
  const postgresPort = requireEnv(env, 'POSTGRES_PORT');
  const valkeyPort = requireEnv(env, 'VALKEY_PORT');

  // The compose *_ADDR variables, rebuilt against Cloud Map names.
  const adAddr = `${host('ad')}:${adPort}`;
  const cartAddr = `${host('cart')}:${cartPort}`;
  const checkoutAddr = `${host('checkout')}:${checkoutPort}`;
  const currencyAddr = `${host('currency')}:${currencyPort}`;
  const emailAddr = `http://${host('email')}:${emailPort}`;
  const paymentAddr = `${host('payment')}:${paymentPort}`;
  const productCatalogAddr = `${host('product-catalog')}:${productCatalogPort}`;
  const quoteAddr = `http://${host('quote')}:${quotePort}`;
  const recommendationAddr = `${host('recommendation')}:${recommendationPort}`;
  const shippingAddr = `http://${host('shipping')}:${shippingPort}`;
  const frontendAddr = `${host('frontend')}:${frontendPort}`;
  const frontendProxyAddr = `${host('frontend-proxy')}:${envoyPort}`;
  const imageProviderHost = host('image-provider');
  const postgresHost = host('astronomy-db');
  const valkeyAddr = `${host('valkey-cart')}:${valkeyPort}`;
  const telemetryDocsHost = host('telemetry-docs');

  const flagdEnv = { FLAGD_HOST: flagdHost, FLAGD_PORT: flagdPort };
  const ipv6 = { IPV6_ENABLED: requireEnv(env, 'IPV6_ENABLED') };

  const repoFile = (relative: string): SeedFile => ({
    sourcePath: path.join(REPO_ROOT, relative),
    name: path.basename(relative),
  });

  return [
    {
      name: 'ad',
      cpu: 512,
      memoryLimitMiB: 1024,
      containers: [
        {
          name: 'ad',
          image: demoImage('ad'),
          ports: [Number(adPort), Number(adPrometheusPort)],
          environment: {
            AD_PORT: adPort,
            AD_PROMETHEUS_PORT: adPrometheusPort,
            ...flagdEnv,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('medium'),
            OTEL_LOGS_EXPORTER: 'otlp',
            OTEL_SERVICE_NAME: 'ad',
            OTEL_EXPERIMENTAL_SDK_TELEMETRY_VERSION: 'latest',
          },
          healthCheck: tcpProbe(adPort),
        },
      ],
    },
    {
      name: 'cart',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'cart',
          image: demoImage('cart'),
          ports: [Number(cartPort)],
          environment: {
            CART_PORT: cartPort,
            ...flagdEnv,
            VALKEY_ADDR: valkeyAddr,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpGrpcEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('high'),
            OTEL_SERVICE_NAME: 'cart',
            ASPNETCORE_URLS: `http://*:${cartPort}`,
          },
        },
      ],
    },
    {
      name: 'checkout',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'checkout',
          image: demoImage('checkout'),
          ports: [Number(checkoutPort)],
          environment: {
            ...flagdEnv,
            CHECKOUT_PORT: checkoutPort,
            CART_ADDR: cartAddr,
            CURRENCY_ADDR: currencyAddr,
            EMAIL_ADDR: emailAddr,
            PAYMENT_ADDR: paymentAddr,
            PRODUCT_CATALOG_ADDR: productCatalogAddr,
            SHIPPING_ADDR: shippingAddr,
            GOMEMLIMIT: '16MiB',
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_PROTOCOL: 'http/protobuf',
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('critical'),
            OTEL_SERVICE_NAME: 'checkout',
          },
          healthCheck: {
            command: ['CMD', '/bin/grpc_health_probe', `-addr=:${checkoutPort}`],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'currency',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'currency',
          image: demoImage('currency'),
          ports: [Number(currencyPort)],
          environment: {
            CURRENCY_PORT: currencyPort,
            ...ipv6,
            VERSION: version,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpGrpcEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('high'),
            OTEL_SERVICE_NAME: 'currency',
          },
          healthCheck: {
            command: ['CMD-SHELL', `nc -z localhost ${currencyPort}`],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'email',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'email',
          image: demoImage('email'),
          ports: [Number(emailPort)],
          environment: {
            APP_ENV: 'production',
            EMAIL_PORT: emailPort,
            ...flagdEnv,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('medium'),
            OTEL_SERVICE_NAME: 'email',
          },
          healthCheck: {
            command: [
              'CMD',
              'ruby',
              '-e',
              `require 'socket'; TCPSocket.new('localhost', ${emailPort}).close`,
            ],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'frontend',
      cpu: 512,
      memoryLimitMiB: 1024,
      containers: [
        {
          name: 'frontend',
          image: demoImage('frontend'),
          ports: [Number(frontendPort)],
          environment: {
            PORT: frontendPort,
            FRONTEND_ADDR: frontendAddr,
            AD_ADDR: adAddr,
            CART_ADDR: cartAddr,
            CHECKOUT_ADDR: checkoutAddr,
            CURRENCY_ADDR: currencyAddr,
            PRODUCT_CATALOG_ADDR: productCatalogAddr,
            RECOMMENDATION_ADDR: recommendationAddr,
            SHIPPING_ADDR: shippingAddr,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpGrpcEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('critical'),
            ENV_PLATFORM: requireEnv(env, 'ENV_PLATFORM'),
            OTEL_SERVICE_NAME: 'frontend',
            // Browser-side traces are posted by the user's browser, so this
            // one has to be the public address rather than a Cloud Map name.
            PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: `${ctx.publicUrl}/otlp-http/v1/traces`,
            WEB_OTEL_SERVICE_NAME: 'frontend-web',
            OTEL_COLLECTOR_HOST: collectorHost,
            ...flagdEnv,
          },
          healthCheck: {
            command: [
              'CMD',
              '/nodejs/bin/node',
              '-e',
              `require('net').connect(${frontendPort},require('os').hostname(),function(){process.exit(0)}).on('error',function(){process.exit(1)})`,
            ],
            startPeriodSeconds: 60,
            intervalSeconds: 10,
            timeoutSeconds: 10,
            retries: 5,
          },
        },
      ],
    },
    {
      name: 'frontend-proxy',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'frontend-proxy',
          image: demoImage('frontend-proxy'),
          ports: [Number(envoyPort), Number(envoyAdminPort)],
          environment: {
            // envsubst renders every one of these into envoy.tmpl.yaml, so
            // they all have to be set even where the upstream service is not
            // part of the core profile (grafana, jaeger, opamp, chatbot,
            // firepit) -- those clusters just never resolve, same as under
            // Compose.
            FRONTEND_PORT: frontendPort,
            FRONTEND_HOST: host('frontend'),
            GRAFANA_PORT: requireEnv(env, 'GRAFANA_PORT'),
            GRAFANA_HOST: requireEnv(env, 'GRAFANA_HOST'),
            JAEGER_UI_PORT: requireEnv(env, 'JAEGER_UI_PORT'),
            JAEGER_HOST: requireEnv(env, 'JAEGER_HOST'),
            OPAMP_SERVER_HOST: requireEnv(env, 'OPAMP_SERVER_HOST'),
            OPAMP_SERVER_UI_PORT: requireEnv(env, 'OPAMP_SERVER_UI_PORT'),
            OTEL_COLLECTOR_HOST: collectorHost,
            IMAGE_PROVIDER_HOST: imageProviderHost,
            IMAGE_PROVIDER_PORT: imageProviderPort,
            OTEL_COLLECTOR_PORT_GRPC: grpcPort,
            OTEL_COLLECTOR_PORT_HTTP: httpPort,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('critical'),
            OTEL_SERVICE_NAME: 'frontend-proxy',
            OTEL_SERVICE_NAMESPACE: namespaceAttr,
            ENVOY_PORT: envoyPort,
            ENVOY_ADDR: requireEnv(env, 'ENVOY_ADDR'),
            ENVOY_ADMIN_PORT: envoyAdminPort,
            FIREPIT_HOST: requireEnv(env, 'FIREPIT_HOST'),
            FIREPIT_PORT: requireEnv(env, 'FIREPIT_PORT'),
            ...flagdEnv,
            FLAGD_UI_HOST: flagdUiHost,
            FLAGD_UI_PORT: flagdUiPort,
            TELEMETRY_DOCS_HOST: telemetryDocsHost,
            TELEMETRY_DOCS_PORT: telemetryDocsPort,
            CHATBOT_HOST: requireEnv(env, 'CHATBOT_HOST'),
            CHATBOT_PORT: requireEnv(env, 'CHATBOT_PORT'),
          },
          healthCheck: tcpProbe(envoyPort),
        },
      ],
    },
    {
      name: 'image-provider',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'image-provider',
          image: demoImage('image-provider'),
          ports: [Number(imageProviderPort)],
          environment: {
            IMAGE_PROVIDER_PORT: imageProviderPort,
            OTEL_COLLECTOR_HOST: collectorHost,
            OTEL_COLLECTOR_PORT_GRPC: grpcPort,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('low'),
            OTEL_SERVICE_NAME: 'image-provider',
          },
          healthCheck: {
            command: [
              'CMD',
              'wget',
              '--quiet',
              '--tries=1',
              '--spider',
              `http://localhost:${imageProviderPort}/status`,
            ],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'load-generator',
      cpu: 1024,
      memoryLimitMiB: 2048,
      registerInDns: false,
      containers: [
        {
          name: 'load-generator',
          image: demoImage('load-generator'),
          ports: [],
          environment: {
            LOAD_GENERATOR_VUS: String(ctx.config.loadGeneratorVus),
            K6_TARGET_URL: `http://${frontendProxyAddr}`,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_PROTOCOL: 'http/protobuf',
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('low'),
            OTEL_SERVICE_NAME: 'load-generator',
            ...flagdEnv,
            FLAGD_OFREP_PORT: flagdOfrepPort,
            K6_OTEL_EXPORTER_PROTOCOL: 'http/protobuf',
            K6_OTEL_HTTP_EXPORTER_ENDPOINT: `${collectorHost}:${httpPort}`,
            K6_OTEL_HTTP_EXPORTER_INSECURE: 'true',
            K6_BROWSER_ENABLED: 'true',
            K6_BROWSER_ARGS: 'no-sandbox,disable-dev-shm-usage',
            K6_OTEL_METRIC_PREFIX: 'k6.',
          },
          healthCheck: {
            command: ['CMD-SHELL', 'pgrep k6'],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 5,
          },
        },
      ],
    },
    {
      name: 'payment',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'payment',
          image: demoImage('payment'),
          ports: [Number(paymentPort)],
          environment: {
            ...ipv6,
            PAYMENT_PORT: paymentPort,
            ...flagdEnv,
            NODE_OPTIONS: '--require @opentelemetry/auto-instrumentations-node/register',
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpGrpcEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_EXPORTER_OTLP_PROTOCOL: 'grpc',
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('critical'),
            OTEL_SERVICE_NAME: 'payment',
          },
          healthCheck: {
            command: [
              'CMD',
              '/nodejs/bin/node',
              '-e',
              `const net=require('net');const c=new net.Socket(); c.setTimeout(2000); c.connect(${paymentPort},'127.0.0.1',()=>{c.destroy();process.exit(0)}); c.on('error',()=>process.exit(1)); c.on('timeout',()=>process.exit(1))`,
            ],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'product-catalog',
      cpu: 256,
      memoryLimitMiB: 512,
      seedFiles: [repoFile('otel-config.yml')],
      containers: [
        {
          name: 'product-catalog',
          image: demoImage('product-catalog'),
          ports: [Number(productCatalogPort)],
          configMountPath: '/etc/otel-demo-ecs',
          environment: {
            PRODUCT_CATALOG_PORT: productCatalogPort,
            ...flagdEnv,
            GOMEMLIMIT: '16MiB',
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpGrpcEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('high'),
            OTEL_SERVICE_NAME: 'product-catalog',
            OTEL_CONFIG_FILE: '/etc/otel-demo-ecs/otel-config.yml',
            OTEL_SEMCONV_STABILITY_OPT_IN: 'database',
            DB_CONNECTION_STRING: `postgres://astronomy_user:${requireEnv(env, 'POSTGRES_ASTRONOMY_PASSWORD')}@${postgresHost}:${postgresPort}/astronomy_db?sslmode=disable`,
          },
          healthCheck: {
            command: ['CMD', '/bin/grpc_health_probe', `-addr=:${productCatalogPort}`],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'quote',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'quote',
          image: demoImage('quote'),
          ports: [Number(quotePort)],
          environment: {
            ...ipv6,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_PHP_AUTOLOAD_ENABLED: 'true',
            QUOTE_PORT: quotePort,
            OTEL_PHP_INTERNAL_METRICS_ENABLED: 'true',
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('low'),
            OTEL_SERVICE_NAME: 'quote',
          },
          healthCheck: {
            command: ['CMD', 'php', '-r', `fsockopen('localhost', ${quotePort}) or die('fail');`],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'recommendation',
      cpu: 512,
      memoryLimitMiB: 1024,
      containers: [
        {
          name: 'recommendation',
          image: demoImage('recommendation'),
          ports: [Number(recommendationPort)],
          environment: {
            RECOMMENDATION_PORT: recommendationPort,
            PRODUCT_CATALOG_ADDR: productCatalogAddr,
            ...flagdEnv,
            OTEL_PYTHON_LOG_CORRELATION: 'true',
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpGrpcEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('medium'),
            OTEL_SERVICE_NAME: 'recommendation',
            PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION: 'python',
          },
          healthCheck: {
            command: ['CMD-SHELL', `nc -z localhost ${recommendationPort}`],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'shipping',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'shipping',
          image: demoImage('shipping'),
          ports: [Number(shippingPort)],
          environment: {
            ...ipv6,
            SHIPPING_PORT: shippingPort,
            QUOTE_ADDR: quoteAddr,
            ...flagdEnv,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_PROTOCOL: 'http/protobuf',
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('high'),
            OTEL_SERVICE_NAME: 'shipping',
          },
          healthCheck: {
            command: ['CMD', '/app/healthcheck'],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'flagd',
      cpu: 512,
      memoryLimitMiB: 1024,
      seedFiles: [repoFile('src/flagd/demo.flagd.json')],
      containers: [
        {
          name: 'flagd',
          image: requireEnv(env, 'FLAGD_IMAGE'),
          command: ['start', '--uri', 'file:./etc/flagd/demo.flagd.json', '--management-port', flagdManagementPort],
          ports: [Number(flagdPort), Number(flagdOfrepPort), Number(flagdManagementPort)],
          configMountPath: '/etc/flagd',
          environment: {
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_PROTOCOL: 'http/protobuf',
            GOMEMLIMIT: '60MiB',
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('low'),
            OTEL_SERVICE_NAME: 'flagd',
          },
        },
        {
          name: 'flagd-ui',
          image: demoImage('flagd-ui'),
          ports: [Number(flagdUiPort)],
          configMountPath: '/app/data',
          environment: {
            FLAGD_UI_PORT: flagdUiPort,
            OTEL_EXPORTER_OTLP_ENDPOINT: otlpHttpEndpoint,
            OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: temporality,
            OTEL_RESOURCE_ATTRIBUTES: resourceAttrs('low'),
            OTEL_SERVICE_NAME: 'flagd-ui',
            SECRET_KEY_BASE: 'yYrECL4qbNwleYInGJYvVnSkwJuSQJ4ijPTx5tirGUXrbznFIBFVJdPl5t6O9ASw',
            PHX_HOST: 'localhost',
          },
          healthCheck: tcpProbe(flagdUiPort),
        },
      ],
    },
    {
      name: 'telemetry-docs',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'telemetry-docs',
          image: demoImage('telemetry-docs'),
          ports: [Number(telemetryDocsPort)],
          environment: {
            TELEMETRY_DOCS_PORT: telemetryDocsPort,
            OTEL_COLLECTOR_HOST: collectorHost,
            OTEL_COLLECTOR_PORT_GRPC: grpcPort,
            OTEL_SERVICE_NAME: 'telemetry-docs',
          },
          healthCheck: {
            command: [
              'CMD',
              'wget',
              '--quiet',
              '--tries=1',
              '--spider',
              `http://localhost:${telemetryDocsPort}/`,
            ],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'astronomy-db',
      cpu: 256,
      memoryLimitMiB: 512,
      seedFiles: [repoFile('src/postgresql/init.sql')],
      containers: [
        {
          name: 'astronomy-db',
          image: requireEnv(env, 'POSTGRES_IMAGE'),
          command: ['postgres', '-c', 'shared_preload_libraries=pg_stat_statements'],
          ports: [Number(postgresPort)],
          configMountPath: '/docker-entrypoint-initdb.d',
          environment: {
            POSTGRES_PASSWORD: requireEnv(env, 'POSTGRES_PASSWORD'),
          },
          healthCheck: {
            command: ['CMD-SHELL', 'pg_isready'],
            startPeriodSeconds: 10,
            intervalSeconds: 5,
            timeoutSeconds: 5,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'valkey-cart',
      cpu: 256,
      memoryLimitMiB: 512,
      containers: [
        {
          name: 'valkey-cart',
          image: requireEnv(env, 'VALKEY_IMAGE'),
          user: 'valkey',
          ports: [Number(valkeyPort)],
          environment: {},
          healthCheck: {
            command: ['CMD-SHELL', 'valkey-cli ping'],
            startPeriodSeconds: 5,
            intervalSeconds: 5,
            timeoutSeconds: 3,
            retries: 10,
          },
        },
      ],
    },
    {
      name: 'otel-collector',
      cpu: 512,
      memoryLimitMiB: 1024,
      seedFiles: [
        repoFile('src/otel-collector/otelcol-config.yml'),
        {
          sourcePath: path.join(CDK_DIR, 'files', 'otelcol-config-extras-aws.yml'),
          name: 'otelcol-config-extras.yml',
        },
      ],
      containers: [
        {
          name: 'otel-collector',
          image: requireEnv(env, 'COLLECTOR_CONTRIB_IMAGE'),
          user: '0:0',
          command: [
            '--config=/etc/otelcol/otelcol-config.yml',
            '--config=/etc/otelcol/otelcol-config-extras.yml',
            '--feature-gates=service.profilesSupport',
          ],
          ports: [Number(grpcPort), Number(httpPort)],
          configMountPath: '/etc/otelcol',
          environment: {
            // The collector binds these, so unlike every other service it
            // needs a listen address rather than its own Cloud Map name.
            OTEL_COLLECTOR_HOST: '0.0.0.0',
            OTEL_COLLECTOR_PORT_GRPC: grpcPort,
            OTEL_COLLECTOR_PORT_HTTP: httpPort,
            AD_PROMETHEUS_ADDR: `${host('ad')}:${adPrometheusPort}`,
            ENVOY_ADMIN_ADDR: `${host('frontend-proxy')}:${envoyAdminPort}`,
            FLAGD_MANAGEMENT_ADDR: `${host('flagd')}:${flagdManagementPort}`,
            FRONTEND_PROXY_ADDR: frontendProxyAddr,
            IMAGE_PROVIDER_HOST: imageProviderHost,
            IMAGE_PROVIDER_PORT: imageProviderPort,
            VALKEY_ADDR: valkeyAddr,
            POSTGRES_HOST: postgresHost,
            POSTGRES_PORT: postgresPort,
            POSTGRES_MONITORING_PASSWORD: requireEnv(env, 'POSTGRES_MONITORING_PASSWORD'),
            GOMEMLIMIT: '160MiB',
            AWS_REGION: ctx.config.region,
            APP_LOG_GROUP: ctx.appLogGroupName,
            OTELCOL_LOG_GROUP: ctx.otelcolLogGroupName,
            // Same value bin/otel-demo-ecs.ts tags every resource with as
            // awsApplication -- see resource/aws_application in
            // otelcol-config-extras-aws.yml, which stamps it onto
            // service.namespace so telemetry lines up with that tag.
            PROJECT_NAME: ctx.config.projectName,
          },
        },
      ],
    },
  ];
}

/** The compose stack's bash //dev/tcp liveness probe. */
function tcpProbe(port: string): HealthCheckSpec {
  return {
    command: ['CMD-SHELL', `bash -c 'echo > /dev/tcp/localhost/${port}'`],
    startPeriodSeconds: 20,
    intervalSeconds: 5,
    timeoutSeconds: 5,
    retries: 10,
  };
}