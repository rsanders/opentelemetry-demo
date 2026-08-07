TF_DIR := terraform
ANSIBLE_DIR := ansible
REPO_DEST := /opt/otel-demo

# Which container `status`/`logs`/`shell` act on, matching the sibling
# deploy/aws-ecs Makefile's SERVICE variable.
SERVICE ?= frontend-proxy
EXEC_SHELL ?= /bin/sh

# The same compose invocation Ansible starts the stack with (see
# ansible/group_vars/all.yml and roles/otel_demo), so `ps`/`logs`/`exec` here
# address the same project rather than a partial view of it. The profile comes
# from the Terraform-generated inventory; before the first `make up` there is
# no inventory yet, so fall back to the "core" default.
COMPOSE_FILES_core := -f compose.yaml
COMPOSE_FILES_full := -f compose.yaml -f compose.full.yaml
COMPOSE_PROFILE := $(shell awk -F= '/^compose_profile=/{print $$2}' $(ANSIBLE_DIR)/inventory.ini 2>/dev/null)
COMPOSE := docker compose $(COMPOSE_FILES_$(or $(COMPOSE_PROFILE),core)) -f compose.aws-override.yml

# Runs a command on the instance over the Terraform-generated SSH key.
# $(1) extra ssh flags, $(2) the command to run in the repo directory.
remote = cd $(TF_DIR) && bash -c "$$(terraform output -raw ssh_command) $(1) 'cd $(REPO_DEST) && $(2)'"

.PHONY: fmt validate plan up update down outputs status restart logs shell otelcol-config ssh ssm

fmt: ## Format the Terraform files
	cd $(TF_DIR) && terraform fmt -recursive

validate: ## Validate the Terraform config (no AWS credentials required)
	cd $(TF_DIR) && terraform init -input=false && terraform validate

plan: ## Show what terraform apply would do
	cd $(TF_DIR) && terraform init -input=false && terraform plan

# apply-with-retry.sh self-heals a reproduced provider quirk: right after a
# `terraform destroy`, re-creating the /otel-demo/* CloudWatch log groups can
# fail once with ResourceAlreadyExistsException even on a clean apply -- the
# create actually succeeds on AWS's side, but the provider doesn't record it
# in state. The script imports whatever it actually created and retries,
# rather than surfacing that as a hard error.
up: ## Create (or update) the AWS infra, then provision + start the demo stack
	cd $(TF_DIR) && terraform init -input=false
	cd $(TF_DIR) && ./apply-with-retry.sh
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini site.yml

update: ## Re-apply infra changes and re-sync/restart the demo stack (the "modify" path)
	cd $(TF_DIR) && ./apply-with-retry.sh
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini site.yml

down: ## Tear down all AWS resources created by this stack
	cd $(TF_DIR) && terraform destroy

outputs: ## Print the app URL, ssh command, etc.
	cd $(TF_DIR) && terraform output

status: ## Show the state of every container on the instance
	@$(call remote,,$(COMPOSE) ps)

restart: ## Restart every container on the instance without re-provisioning
	@$(call remote,,$(COMPOSE) restart)

logs: ## Tail one service's container logs (SERVICE=cart)
	@$(call remote,-t,$(COMPOSE) logs --follow --tail=100 $(SERVICE))

# The ECS deployment's `make shell` opens a shell in a task's container; this
# is the compose equivalent. Use `make ssh`/`make ssm` for the host itself.
shell: ## Open a shell in a running container (SERVICE=cart)
	@$(call remote,-t,$(COMPOSE) exec $(SERVICE) $(EXEC_SHELL))

# print-config resolves the same --config layers (and feature gate) the
# container is actually launched with (see compose.yaml's otel-collector
# command) and prints the merged result -- the config after otelcol-config.yml
# and otelcol-config-extras.yml are deep-merged, not either file on its own.
otelcol-config: ## Print the otel-collector's fully resolved/merged configuration
	@$(call remote,-t,$(COMPOSE) exec otel-collector /otelcol-contrib print-config --config=/etc/otelcol-config.yml --config=/etc/otelcol-config-extras.yml --feature-gates=service.profilesSupport)

ssh: ## SSH into the demo instance
	cd $(TF_DIR) && bash -c "$$(terraform output -raw ssh_command)"

ssm: ## Open a Session Manager shell on the demo instance (no SSH key/open port needed)
	cd $(TF_DIR) && bash -c "$$(terraform output -raw ssm_command)"
