# widget-shop: one app box and one RDS instance.
#   make stacks VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b PUBLIC_SUBNET=subnet-c [REHEARSAL=true]
#   make deploy [TAGS="web=20260101 worker=20260101"]
RDS_STACK = acme-widget-shop-rds
BOX_STACK = acme-widget-shop-box
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
	bash ./deploy-box.sh $(TAGS)
