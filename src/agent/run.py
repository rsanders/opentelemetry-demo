#!/usr/bin/python

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


import asyncio
import logging
import os

from dotenv import load_dotenv
from opentelemetry import _logs, metrics, trace
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.logging.handler import LoggingHandler
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import DropAggregation, View
from src.agents.agents import Agent
from src.agents.telemetry import enrich_gen_ai_span
from traceloop.sdk import Traceloop

load_dotenv()

# The LangChain instrumentation creates its instruments before Traceloop
# configures a global MeterProvider. Keep those proxy instruments, but configure
# the provider here so the standard token metric is emitted exactly once with
# the complete semantic-convention attribute set.
os.environ["TRACELOOP_METRICS_ENABLED"] = "false"
Traceloop.init(
    app_name=os.getenv("OTEL_SERVICE_NAME", "agent"),
    api_endpoint=os.getenv("TRACELOOP_BASE_URL", "http://localhost:4318"),
    span_postprocess_callback=enrich_gen_ai_span,
)


def _configure_metrics() -> None:
    reader = PeriodicExportingMetricReader(OTLPMetricExporter())
    provider = MeterProvider(
        metric_readers=[reader],
        resource=trace.get_tracer_provider().resource,
        views=[
            View(
                instrument_name="gen_ai.client.token.usage",
                meter_name="opentelemetry.instrumentation.langchain",
                aggregation=DropAggregation(),
            )
        ],
    )
    metrics.set_meter_provider(provider)


def _configure_logging() -> None:
    provider = LoggerProvider(resource=trace.get_tracer_provider().resource)
    provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter())
    )
    _logs.set_logger_provider(provider)
    logging.basicConfig(
        level=logging.INFO,
        force=True,
        handlers=[logging.StreamHandler(), LoggingHandler(logger_provider=provider)],
    )


_configure_metrics()
_configure_logging()

HTTPXClientInstrumentor().instrument()


async def start_servers():
    """Run the LangGraph Agent server"""
    tasks = []
    agent = Agent()
    FastAPIInstrumentor.instrument_app(agent.app)
    tasks.append(agent.launch())
    await asyncio.gather(*tasks)


if __name__ == "__main__":
    try:
        asyncio.run(start_servers())
    except KeyboardInterrupt:
        logging.info("Shutting down servers...")
