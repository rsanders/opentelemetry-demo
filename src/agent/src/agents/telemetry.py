#!/usr/bin/python

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

import os
from typing import Any
from urllib.parse import urlparse

from opentelemetry import _logs, metrics

_SCHEMA_URL = "https://opentelemetry.io/schemas/1.40.0"
_INSTRUMENTATION_SCOPE = "opentelemetry.demo.agent"
_TOKEN_USAGE_EVENT = "gen_ai.client.inference.operation.details"

_meter = metrics.get_meter(
    _INSTRUMENTATION_SCOPE,
    schema_url=_SCHEMA_URL,
)
_token_histogram = _meter.create_histogram(
    "gen_ai.client.token.usage",
    unit="{token}",
    description="Number of input and output tokens used.",
)
_event_logger = _logs.get_logger(
    _INSTRUMENTATION_SCOPE,
    schema_url=_SCHEMA_URL,
)


def _first_value(mapping: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = mapping.get(key)
        if value is not None:
            return value
    return None


def _token_count(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        count = int(value)
    except (TypeError, ValueError):
        return None
    return count if count >= 0 else None


def _response_metadata(result: Any) -> tuple[dict[str, Any], list[Any]]:
    messages = []
    for generation_list in getattr(result, "generations", []) or []:
        for generation in generation_list:
            message = getattr(generation, "message", None)
            if message is not None:
                messages.append(message)

    metadata = dict(getattr(result, "llm_output", None) or {})
    if messages:
        response_metadata = getattr(messages[0], "response_metadata", None) or {}
        for key, value in response_metadata.items():
            metadata.setdefault(key, value)
    return metadata, messages


def _extract_usage(
    metadata: dict[str, Any], messages: list[Any]
) -> tuple[int | None, int | None]:
    usage = metadata.get("token_usage") or metadata.get("usage") or {}
    input_tokens = _token_count(
        _first_value(usage, "prompt_tokens", "input_tokens", "input_token_count")
    )
    output_tokens = _token_count(
        _first_value(
            usage,
            "completion_tokens",
            "output_tokens",
            "generated_token_count",
        )
    )

    if messages:
        usage_metadata = getattr(messages[0], "usage_metadata", None) or {}
        if input_tokens is None:
            input_tokens = _token_count(usage_metadata.get("input_tokens"))
        if output_tokens is None:
            output_tokens = _token_count(usage_metadata.get("output_tokens"))

    return input_tokens, output_tokens


def _finish_reasons(messages: list[Any]) -> list[str]:
    reasons = []
    for message in messages:
        reason = (getattr(message, "response_metadata", None) or {}).get(
            "finish_reason"
        )
        if reason is not None and str(reason) not in reasons:
            reasons.append(str(reason))
    return reasons


def _server_attributes() -> dict[str, str | int]:
    endpoint = os.getenv("LLM_BASE_URL")
    if not endpoint:
        return {}
    parsed = urlparse(endpoint)
    if not parsed.hostname:
        return {}
    attributes: dict[str, str | int] = {"server.address": parsed.hostname}
    try:
        port = parsed.port
    except ValueError:
        return {}
    if port is None:
        port = 443 if parsed.scheme == "https" else 80
    attributes["server.port"] = port
    return attributes


def enrich_gen_ai_span(span: Any) -> None:
    attributes = getattr(span, "_attributes", None)
    if not attributes or attributes.get("gen_ai.operation.name") != "chat":
        return

    attributes["gen_ai.provider.name"] = (
        os.getenv("GEN_AI_PROVIDER_NAME") or "openai"
    )
    attributes.update(_server_attributes())


def record_token_usage(result: Any, request_model: str) -> None:
    metadata, messages = _response_metadata(result)
    input_tokens, output_tokens = _extract_usage(metadata, messages)
    if input_tokens is None and output_tokens is None:
        return

    response_model = _first_value(metadata, "model_name", "model", "model_id")
    attributes: dict[str, Any] = {
        "gen_ai.operation.name": "chat",
        "gen_ai.provider.name": os.getenv("GEN_AI_PROVIDER_NAME") or "openai",
        "gen_ai.request.model": request_model,
        **_server_attributes(),
    }
    if response_model:
        attributes["gen_ai.response.model"] = str(response_model)

    for token_type, count in (("input", input_tokens), ("output", output_tokens)):
        if count is not None:
            _token_histogram.record(
                count,
                {**attributes, "gen_ai.token.type": token_type},
            )

    response_id = _first_value(metadata, "id", "response_id")
    if response_id:
        attributes["gen_ai.response.id"] = str(response_id)
    reasons = _finish_reasons(messages)
    if reasons:
        attributes["gen_ai.response.finish_reasons"] = reasons
    if input_tokens is not None:
        attributes["gen_ai.usage.input_tokens"] = input_tokens
    if output_tokens is not None:
        attributes["gen_ai.usage.output_tokens"] = output_tokens

    _event_logger.emit(
        event_name=_TOKEN_USAGE_EVENT,
        body="GenAI chat completion token usage",
        attributes=attributes,
    )
