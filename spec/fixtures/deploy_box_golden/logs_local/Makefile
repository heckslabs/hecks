# scratch-fixture: one app box and one RDS instance.
#   make stacks VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b PUBLIC_SUBNET=subnet-c [REHEARSAL=true]
#   make deploy [TAGS="web=20260101 worker=20260101"]
# `make stacks` keeps a live box on the image it runs, so an update never replaces the instance.
# To move to a newer image on purpose:  make stacks ... AMI_ID=ami-...
RDS_STACK = hecks-scratch-fixture-rds
BOX_STACK = hecks-scratch-fixture-box
# true makes a throwaway pair: the database is deleted with its stack and the box has no
# Elastic IP. The default is a production pair, with deletion protection.
REHEARSAL ?= false
AMI_ID ?=

HECKS ?= hecks

.PHONY: stacks deploy
stacks:
	aws cloudformation deploy --template-file rds.yaml --stack-name $(RDS_STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS) Rehearsal=$(REHEARSAL)
	@AMI="$(AMI_ID)"; SRC="given as AMI_ID"; \
	if [ -z "$$AMI" ]; then \
		BOX=$$(aws cloudformation describe-stack-resource --stack-name $(BOX_STACK) --logical-resource-id Box --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null); \
		case "$$BOX" in \
			i-*) AMI=$$(aws ec2 describe-instances --instance-ids "$$BOX" --query "Reservations[0].Instances[0].ImageId" --output text); SRC="pinned: the image $$BOX runs" ;; \
			*) AMI=$$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 --query Parameter.Value --output text); SRC="new: no $(BOX_STACK) stack yet, so the latest image" ;; \
		esac; \
	fi; \
	case "$$AMI" in ami-*) ;; *) echo "no ami- image found for $(BOX_STACK): pass one with AMI_ID=ami-..." >&2; exit 1 ;; esac; \
	echo "==> AmiId $$AMI ($$SRC)"; \
	aws cloudformation deploy --template-file box.yaml --stack-name $(BOX_STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) SubnetId=$(PUBLIC_SUBNET) \
		DbSecurityGroupId=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecurityGroupId'].OutputValue" --output text) \
		DbSecretArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text) \
		AmiId=$$AMI \
		AlertTopicArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" --output text) \
		Rehearsal=$(REHEARSAL)

deploy:
	@err=$$(mktemp); run=deploy-$$(date -u +%Y%m%d%H%M%S); \
	$(HECKS) deploy box_roll.run project="$(CURDIR)" run="$$run" $(if $(TAGS),tags="$(TAGS)") \
	  $(if $(SKIP_POST_DEPLOY_SMOKE),skip_smoke=true) --wait 2>"$$err"; rc=$$?; \
	if [ $$rc -ne 0 ] && grep -q '^cannot open Hecks' "$$err"; then \
	  echo "==> the deploy record was NOT written: $$(grep -m1 '^cannot open Hecks' "$$err")" >&2; \
	  echo "    one-time setup on this machine: a database AND a non-superuser role that owns it" >&2; \
	  echo "    (a superuser skips the era write-fence, so createdb alone fails), then set" >&2; \
	  echo "    HECKS_DATABASE=postgres://<role>@localhost/<db>" >&2; \
	  echo "    deploying anyway so the deploy is not lost" >&2; \
	  rm -f "$$err"; bash ./deploy-box.sh $(TAGS); rc=$$?; \
	  echo "==> deploy exit $$rc. The deploy record was NOT written: the database is unavailable (see above)." >&2; \
	  [ $$rc -ne 0 ] || rc=24; exit $$rc; \
	fi; \
	cat "$$err" >&2; rm -f "$$err"; exit $$rc
