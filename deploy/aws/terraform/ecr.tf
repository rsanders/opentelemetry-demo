# Private image repos for the agent/chatbot/mcp GenAI layer (enable_agent_layer).
# None of these three images are published anywhere this deploy can reach:
# ghcr.io/open-telemetry/demo:latest-{agent,chatbot,mcp} don't exist upstream,
# and this fork's own CI is barred from pushing to GHCR on forked repos. Rather
# than building them from source on every deploy (make update would then wait
# on a Python dependency install each time), they're built and pushed here
# once -- or after each source change -- via `make push-agentic-images`, and
# the instance just pulls them like any other service.
locals {
  agentic_services = ["agent", "chatbot", "mcp"]
}

resource "aws_ecr_repository" "agentic" {
  for_each = var.enable_agent_layer ? toset(local.agentic_services) : []
  name     = "${var.project_name}-${each.key}"
}

resource "aws_ecr_lifecycle_policy" "agentic" {
  for_each   = aws_ecr_repository.agentic
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 5 pushed images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
