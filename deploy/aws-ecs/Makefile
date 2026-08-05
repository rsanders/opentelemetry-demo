# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

CDK_DIR := cdk
CDK := npx cdk

# Read from cdk/config.json so the Makefile and the CDK app agree on where the
# stack lives; both fall back to the same defaults when config.json is absent.
read_config = $(shell node -e "let c={};try{c=require('./$(CDK_DIR)/config.json')}catch(e){};console.log(c.$(1)||'$(2)')")
STACK := $(call read_config,projectName,otel-demo-ecs)
REGION := $(call read_config,region,us-east-1)

# Which container `make shell` / `make logs` act on. CONTAINER defaults to
# SERVICE; they differ only for flagd, which also carries the flagd-ui
# container (see lib/services.ts).
SERVICE ?= frontend-proxy
CONTAINER ?= $(SERVICE)
EXEC_SHELL ?= /bin/sh

.PHONY: install fmt validate plan bootstrap up update down outputs status logs shell ssh ssm

install: ## Install the CDK app's dependencies
	cd $(CDK_DIR) && npm ci

fmt: install ## Format the CDK TypeScript sources
	cd $(CDK_DIR) && npx prettier --write "bin/**/*.ts" "lib/**/*.ts"

validate: install ## Type-check and synthesize the stack (no AWS credentials required)
	cd $(CDK_DIR) && npx tsc --noEmit && $(CDK) synth --quiet

plan: install ## Show what a deploy would change
	cd $(CDK_DIR) && $(CDK) diff

bootstrap: install ## Prepare the account/region for CDK deployments (idempotent)
	cd $(CDK_DIR) && $(CDK) bootstrap

up: install bootstrap ## Create (or update) all AWS resources and start the demo stack
	cd $(CDK_DIR) && $(CDK) deploy --require-approval never

update: install ## Re-deploy after a code or config change (the "modify" path)
	cd $(CDK_DIR) && $(CDK) deploy --require-approval never

down: install ## Tear down all AWS resources created by this stack
	cd $(CDK_DIR) && $(CDK) destroy

outputs: ## Print the app URL, static IP, cluster name, etc.
	@aws cloudformation describe-stacks --stack-name $(STACK) --region $(REGION) \
		--query 'Stacks[0].Outputs[].{Output:OutputKey,Value:OutputValue}' --output table

status: ## Show running/desired task counts for every service
	@aws ecs list-services --cluster $(STACK) --region $(REGION) --query 'serviceArns' --output text \
		| tr '\t' '\n' | xargs -n 10 aws ecs describe-services --cluster $(STACK) --region $(REGION) --services \
		| node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{for(const x of JSON.parse(s).services)console.log(x.runningCount+'/'+x.desiredCount+'\t'+x.status+'\t'+x.serviceName)})"

logs: ## Tail one service's container logs (SERVICE=cart)
	aws logs tail /$(STACK)/$(SERVICE) --region $(REGION) --follow

# ECS Exec is the Fargate equivalent of the EC2 deployment's `make ssm`: a
# shell opened through the AWS API rather than an inbound port, logged in
# CloudTrail. It needs the Session Manager plugin for the AWS CLI.
shell: ## Open a shell in a running container (SERVICE=cart)
	@task=$$(aws ecs list-tasks --cluster $(STACK) --service-name $(SERVICE) --region $(REGION) \
		--query 'taskArns[0]' --output text); \
	if [ "$$task" = "None" ] || [ -z "$$task" ]; then echo "No running task for service '$(SERVICE)'"; exit 1; fi; \
	aws ecs execute-command --cluster $(STACK) --task "$$task" --container $(CONTAINER) \
		--region $(REGION) --interactive --command "$(EXEC_SHELL)"

# Kept so the target names match the sibling deploy/aws Makefile. There is no
# host to SSH into here -- every service is a Fargate task.
ssh: shell ## Alias for `make shell`
ssm: shell ## Alias for `make shell`