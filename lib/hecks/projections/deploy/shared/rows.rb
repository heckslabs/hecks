module Hecks
  module Projections
    module Deploy
      module Shared
        # The rows of the stack-to-bastion contract: each `template.yaml` Output the bastion reads
        # and each `bastion.yaml` Parameter it fills. Extended onto `Shared`.
        module Rows
          private

          def output(key, var, ref)
            { key: key, var: var, ref: ref }
          end

          def core_outputs(network, secret_intrinsic, compute_security_group_ref)
            db_id = network.db_id
            [
              output("VpcId", "VPC_ID", "!Ref #{db_id}Vpc"),
              output("DbSecurityGroupId", "DB_SG_ID", "!Ref #{db_id}SecurityGroup"),
              output("DatabaseEndpoint", "DB_HOST", "!GetAtt #{network.db_ref_id}.Endpoint.Address"),
              output("DatabaseSecretArn", "DB_SECRET_ARN", secret_intrinsic),
              # Read live by a Shared-mode domain to attach its compute to this VPC.
              output("FunctionSecurityGroupId", "FN_SG_ID", compute_security_group_ref),
              output("PrivateSubnetAId", "PRIVATE_SUBNET_A_ID", "!Ref #{db_id}SubnetA"),
              output("PrivateSubnetBId", "PRIVATE_SUBNET_B_ID", "!Ref #{db_id}SubnetB")
            ]
          end

          # A VPC accepts one Internet Gateway; `bastion.yaml` must reuse this subnet's rather than
          # mint its own (Resource.AlreadyAssociated). The bastion subnet is a separate AZ-1 subnet:
          # EC2 instances cannot launch in AZ index 0 on this account, which only the bastion hits.
          def oauth_outputs(db_id)
            [output("PublicSubnetId", "PUBLIC_SUBNET_ID", "!Ref #{db_id}PublicSubnet"),
             output("BastionSubnetId", "BASTION_SUBNET_ID", "!Ref #{db_id}BastionPublicSubnet")]
          end

          def parameter(name, from_output, type)
            { name: name, from_output: from_output, type: type }
          end

          def oauth_parameters
            [parameter("PublicSubnetId", "PublicSubnetId", "AWS::EC2::Subnet::Id"),
             parameter("BastionSubnetId", "BastionSubnetId", "AWS::EC2::Subnet::Id")]
          end
        end
      end
    end
  end
end
