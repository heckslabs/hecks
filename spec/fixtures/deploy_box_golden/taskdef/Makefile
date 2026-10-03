# widget-shop: one app box and one RDS instance.
#   make stacks VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b PUBLIC_SUBNET=subnet-c [REHEARSAL=true] [MEDIA_BUCKET=name]
#   make deploy [TASKDEF=family:revision]
RDS_STACK = hecks-widget-shop-rds
BOX_STACK = hecks-widget-shop-box
REHEARSAL ?= false
MEDIA_BUCKET ?=

.PHONY: stacks deploy
stacks:
	aws cloudformation deploy --template-file rds.yaml --stack-name $(RDS_STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS) Rehearsal=$(REHEARSAL)
	aws cloudformation deploy --template-file box.yaml --stack-name $(BOX_STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) SubnetId=$(PUBLIC_SUBNET) Rehearsal=$(REHEARSAL) MediaBucket=$(MEDIA_BUCKET) \
		DbSecurityGroupId=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecurityGroupId'].OutputValue" --output text) \
		DbSecretArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text) \
		AlertTopicArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" --output text)

deploy:
	bash ./deploy-box.sh $(TASKDEF)
