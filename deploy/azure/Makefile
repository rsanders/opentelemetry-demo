TF_DIR := terraform
ANSIBLE_DIR := ansible
REPO_DEST := /opt/otel-demo
SERVICE ?= frontend-proxy
EXEC_SHELL ?= /bin/sh
COMPOSE := docker compose -f compose.yaml -f compose.azure-override.yml

remote = cd $(TF_DIR) && bash -c "$$(terraform output -raw ssh_command) $(1) 'cd $(REPO_DEST) && $(2)'"

.PHONY: fmt validate plan up update down outputs status logs shell container-shell ssh

fmt:
	cd $(TF_DIR) && terraform fmt -recursive

validate:
	cd $(TF_DIR) && terraform init -input=false && terraform validate
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check -i inventory.ini.example site.yml

plan:
	cd $(TF_DIR) && terraform init -input=false && terraform plan

up:
	cd $(TF_DIR) && terraform init -input=false && terraform apply -auto-approve
	cd $(ANSIBLE_DIR) && OTEL_SERVICE_VERSION="$$(git -C ../.. rev-parse HEAD)-$$(date +%s)" ansible-playbook -i inventory.ini site.yml

update:
	cd $(TF_DIR) && terraform apply -auto-approve
	cd $(ANSIBLE_DIR) && OTEL_SERVICE_VERSION="$$(git -C ../.. rev-parse HEAD)-$$(date +%s)" ansible-playbook -i inventory.ini site.yml

down:
	cd $(TF_DIR) && terraform destroy -auto-approve

outputs:
	cd $(TF_DIR) && terraform output

status:
	@$(call remote,,$(COMPOSE) ps)

logs:
	@$(call remote,-t,$(COMPOSE) logs --follow --tail=100 $(SERVICE))

shell: ssh

container-shell:
	@$(call remote,-t,$(COMPOSE) exec $(SERVICE) $(EXEC_SHELL))

ssh:
	cd $(TF_DIR) && bash -c "$$(terraform output -raw ssh_command)"
