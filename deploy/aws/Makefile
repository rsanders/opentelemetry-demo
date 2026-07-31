TF_DIR := terraform
ANSIBLE_DIR := ansible

.PHONY: fmt validate plan up update down outputs ssh

fmt: ## Format the Terraform files
	cd $(TF_DIR) && terraform fmt -recursive

validate: ## Validate the Terraform config (no AWS credentials required)
	cd $(TF_DIR) && terraform init -input=false && terraform validate

plan: ## Show what terraform apply would do
	cd $(TF_DIR) && terraform init -input=false && terraform plan

up: ## Create (or update) the AWS infra, then provision + start the demo stack
	cd $(TF_DIR) && terraform init -input=false && terraform apply
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini site.yml

update: ## Re-apply infra changes and re-sync/restart the demo stack (the "modify" path)
	cd $(TF_DIR) && terraform apply
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini site.yml

down: ## Tear down all AWS resources created by this stack
	cd $(TF_DIR) && terraform destroy

outputs: ## Print the app URL, ssh command, etc.
	cd $(TF_DIR) && terraform output

ssh: ## SSH into the demo instance
	cd $(TF_DIR) && terraform output -raw ssh_command | bash
