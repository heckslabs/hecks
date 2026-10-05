# widget-shop: one app box and one RDS instance.
#   make stacks VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b PUBLIC_SUBNET=subnet-c [REHEARSAL=true]
#   make deploy [TAGS="web=20260101 worker=20260101"]
RDS_STACK = hecks-widget-shop-rds
BOX_STACK = hecks-widget-shop-box
# true makes a throwaway pair: the database is deleted with its stack and the box has no
# Elastic IP. The default is a production pair, with deletion protection.
REHEARSAL ?= false

.PHONY: stacks deploy
stacks:
	aws cloudformation deploy --template-file rds.yaml --stack-name $(RDS_STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS) Rehearsal=$(REHEARSAL)
	aws cloudformation deploy --template-file box.yaml --stack-name $(BOX_STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) SubnetId=$(PUBLIC_SUBNET) \
		DbSecurityGroupId=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecurityGroupId'].OutputValue" --output text) \
		DbSecretArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text) \
		AlertTopicArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" --output text) \
		Rehearsal=$(REHEARSAL)

deploy:
	@err=$$(mktemp); run=deploy-$$(date -u +%Y%m%d%H%M%S); \
	$(HECKS) deploy box_roll.run project="$(CURDIR)" run="$$run" $(if $(TAGS),tags="$(TAGS)") \
	  $(if $(SKIP_POST_DEPLOY_SMOKE),skip_smoke=true) --wait 2>"$$err"; rc=$$?; \
	if [ $$rc -ne 0 ] && grep -q '^cannot open Hecks' "$$err"; then \
	  echo "==> the deploy record was NOT written: $$(grep -m1 '^cannot open Hecks' "$$err")" >&2; \
	  echo "    one-time setup on this machine: createdb hecks, or set HECKS_DATABASE to a Postgres URL" >&2; \
	  echo "    deploying anyway so the deploy is not lost" >&2; \
	  rm -f "$$err"; bash ./deploy-box.sh $(TAGS) || exit $$?; TASKDEF="$(TASKDEF)" bash ./smoke-after-deploy.sh; rc=$$?; \
	  echo "==> deploy exit $$rc. The deploy record was NOT written: the database is unavailable (see above)." >&2; \
	  [ $$rc -ne 0 ] || rc=24; exit $$rc; \
	fi; \
	cat "$$err" >&2; rm -f "$$err"; [ $$rc -eq 0 ] || exit $$rc; \
	[ -z "$(SKIP_POST_DEPLOY_SMOKE)" ] || exit 0; \
	smoke=$$($(HECKS) deploy smoke_run.verdict run="$$run"); \
	status=$$(echo "$$smoke" | jq -r '.[0].status // "missing"'); \
	[ "$$status" = passed ] && exit 0; \
	echo "==> the post-deploy smoke ended $$status (hecks deploy smoke_run.verdict run=$$run)" >&2; \
	echo "$$smoke" | jq -r '.[0].refusal.value // empty' >&2; exit 1

include hosting.mk
