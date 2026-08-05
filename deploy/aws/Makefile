TF_DIR := terraform
ANSIBLE_DIR := ansible

.PHONY: fmt validate plan up update down outputs ssh ssm

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

ssh: ## SSH into the demo instance
	cd $(TF_DIR) && bash -c "$$(terraform output -raw ssh_command)"

ssm: ## Open a Session Manager shell on the demo instance (no SSH key/open port needed)
	cd $(TF_DIR) && bash -c "$$(terraform output -raw ssm_command)"
