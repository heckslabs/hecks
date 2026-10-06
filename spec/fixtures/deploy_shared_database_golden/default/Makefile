# hecks-platform-rds: the shared RDS instance that each site's own box stack keeps a database on.
#   make stack VPC=vpc-... PRIVATE_SUBNETS=subnet-a,subnet-b [BASTION_SG=sg-...] [ALERT_EMAIL=you@example.com] [REHEARSAL=true]
STACK = hecks-platform-rds
# true makes a throwaway copy: no deletion protection and no final snapshot. The default is the real instance.
REHEARSAL ?= false

.PHONY: stack
stack:
	aws cloudformation deploy --template-file rds.yaml --stack-name $(STACK) --capabilities CAPABILITY_IAM \
		--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS) Rehearsal=$(REHEARSAL) \
		$(if $(BASTION_SG),BastionSecurityGroupId=$(BASTION_SG)) $(if $(ALERT_EMAIL),AlertEmail=$(ALERT_EMAIL))
