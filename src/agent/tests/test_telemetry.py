# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

import os
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from src.agents import telemetry


class TokenUsageTelemetryTest(unittest.TestCase):
    def setUp(self):
        telemetry._token_histogram = MagicMock()
        telemetry._event_logger = MagicMock()

    def test_records_metric_and_log_event_from_llm_output(self):
        message = SimpleNamespace(
            response_metadata={"finish_reason": "stop"},
            usage_metadata=None,
        )
        result = SimpleNamespace(
            llm_output={
                "id": "chatcmpl-123",
                "model_name": "gpt-5-nano-2026-08-07",
                "token_usage": {
                    "prompt_tokens": 41,
                    "completion_tokens": 7,
                    "total_tokens": 48,
                },
            },
            generations=[[SimpleNamespace(message=message)]],
        )

        with patch.dict(
            os.environ,
            {
                "GEN_AI_PROVIDER_NAME": "openai",
                "LLM_BASE_URL": "https://api.openai.com/v1",
            },
            clear=False,
        ):
            telemetry.record_token_usage(result, "gpt-5-nano")

        calls = telemetry._token_histogram.record.call_args_list
        self.assertEqual([call.args[0] for call in calls], [41, 7])
        self.assertEqual(
            [call.args[1]["gen_ai.token.type"] for call in calls],
            ["input", "output"],
        )
        self.assertEqual(
            calls[0].args[1]["gen_ai.operation.name"], "chat"
        )
        self.assertEqual(calls[0].args[1]["server.address"], "api.openai.com")
        self.assertEqual(calls[0].args[1]["server.port"], 443)

        event = telemetry._event_logger.emit.call_args.kwargs
        self.assertEqual(
            event["event_name"], "gen_ai.client.inference.operation.details"
        )
        self.assertEqual(event["attributes"]["gen_ai.usage.input_tokens"], 41)
        self.assertEqual(event["attributes"]["gen_ai.usage.output_tokens"], 7)
        self.assertEqual(
            event["attributes"]["gen_ai.response.finish_reasons"], ["stop"]
        )

    def test_uses_langchain_usage_metadata_fallback(self):
        message = SimpleNamespace(
            response_metadata={},
            usage_metadata={"input_tokens": 9, "output_tokens": 3},
        )
        result = SimpleNamespace(
            llm_output=None,
            generations=[[SimpleNamespace(message=message)]],
        )

        telemetry.record_token_usage(result, "test-model")

        self.assertEqual(
            [call.args[0] for call in telemetry._token_histogram.record.call_args_list],
            [9, 3],
        )

    def test_does_not_emit_without_provider_reported_usage(self):
        result = SimpleNamespace(llm_output={}, generations=[])

        telemetry.record_token_usage(result, "test-model")

        telemetry._token_histogram.record.assert_not_called()
        telemetry._event_logger.emit.assert_not_called()

    def test_enriches_chat_span_with_provider_endpoint(self):
        span = SimpleNamespace(
            _attributes={"gen_ai.operation.name": "chat"}
        )

        with patch.dict(
            os.environ,
            {
                "GEN_AI_PROVIDER_NAME": "openai",
                "LLM_BASE_URL": "https://api.openai.com/v1",
            },
            clear=False,
        ):
            telemetry.enrich_gen_ai_span(span)

        self.assertEqual(span._attributes["gen_ai.provider.name"], "openai")
        self.assertEqual(span._attributes["server.address"], "api.openai.com")
        self.assertEqual(span._attributes["server.port"], 443)

    def test_does_not_enrich_non_inference_span(self):
        span = SimpleNamespace(
            _attributes={"gen_ai.operation.name": "execute_tool"}
        )

        telemetry.enrich_gen_ai_span(span)

        self.assertEqual(
            span._attributes,
            {"gen_ai.operation.name": "execute_tool"},
        )


if __name__ == "__main__":
    unittest.main()
