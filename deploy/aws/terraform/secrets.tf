# LLM API key for the optional agent/chatbot/mcp GenAI layer (enable_agent_layer).
# Stored in Secrets Manager rather than baked into the compose override or .env
# so it never lands in the rsynced repo copy on disk -- the instance's own IAM
# role reads it directly from Secrets Manager at container-start time (see
# roles/otel_demo/tasks/main.yml's "Fetch LLM API key" task) and it exists only
# in the docker compose child process's environment and the running `agent`
# container's environment, never in a file.
resource "aws_secretsmanager_secret" "llm_api_key" {
  count       = var.enable_agent_layer ? 1 : 0
  name        = "${var.project_name}-llm-api-key"
  description = "OpenAI/Azure OpenAI-compatible API key for the agent service (compose.agent.yaml)."
}

resource "aws_secretsmanager_secret_version" "llm_api_key" {
  count         = var.enable_agent_layer ? 1 : 0
  secret_id     = aws_secretsmanager_secret.llm_api_key[0].id
  secret_string = var.llm_api_key

  lifecycle {
    precondition {
      condition     = var.llm_api_key != "" && var.llm_base_url != "" && var.llm_model != ""
      error_message = "enable_agent_layer = true requires llm_api_key, llm_base_url, and llm_model to all be set in terraform.tfvars."
    }
  }
}
