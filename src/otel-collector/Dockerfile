# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG COLLECTOR_CONTRIB_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.157.0

FROM ghcr.io/grpc-ecosystem/grpc-health-probe:v0.4.53@sha256:a732f1b3a737926c2902393809b344c9f293b62f7069dbd0614caebd298b2e8d AS grpc-health-probe

# The published collector image has no shell and no HTTP/gRPC client, so
# there is nothing compose.yaml's healthcheck can exec into it to run. Wrap
# it with only the probe binary added; the collector itself is unmodified.
FROM ${COLLECTOR_CONTRIB_IMAGE}

COPY --from=grpc-health-probe /ko-app/grpc-health-probe /grpc_health_probe
