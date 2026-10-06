module Hecks
  module Projections
    module Deploy
      module Box
        # The parts of a box deploy that change when its database is one of several on a shared RDS
        # instance, each client in its own database with its own login role (ADR 0092). Mixed into
        # `Box`. Everything here returns the dedicated-instance text unchanged when the plan has no
        # `shared_database`, so a site with its own instance generates the same files as before.
        module SharedDatabase
          # @param plan [Settings::Plan] the resolved settings
          # @return [Hash{String => String}] the Makefile markers that depend on where the database
          #   lives
          def database_makefile_values(plan)
            return dedicated_makefile_values unless plan.shared?

            { "WHAT" => "one app box and a database on the shared instance #{plan.rds_stack}",
              "REHEARSAL_NOTE" => "# true gives the box no Elastic IP. It never deletes the shared instance\n" \
                                  "# or this site's database.\n",
              "RDS_DEPLOY" => "", "DB_SECRET_PARAM" => "\t\tDbSecretArn=$$(aws secretsmanager describe-secret --secret-id " \
                                                       "#{plan.infra_name}/database --query ARN --output text) \\",
              "PHONY" => ".PHONY: stacks deploy provision", "PROVISION" => provision_target(plan) }
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the line of `deploy-box.sh` that finds the secret the containers read
          def database_secret_line(plan)
            return 'DB_SECRET=$(out "$RDS_STACK" DbSecretArn)' unless plan.shared?

            "DB_SECRET=$(aws secretsmanager describe-secret --secret-id #{plan.infra_name}/database --query ARN --output text)"
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] `provision-database.sh`, which creates the site's database, role and
          #   secret
          def provision_database_sh(plan)
            template("provision-database.sh.tmpl", "STACK" => plan.infra_name, "RDS_STACK" => plan.rds_stack,
                                                   "DATABASE" => plan.database_name)
          end

          private

          def dedicated_makefile_values
            { "WHAT" => "one app box and one RDS instance",
              "REHEARSAL_NOTE" => "# true makes a throwaway pair: the database is deleted with its stack and the box has no\n" \
                                  "# Elastic IP. The default is a production pair, with deletion protection.\n",
              "RDS_DEPLOY" => rds_deploy_lines, "DB_SECRET_PARAM" => dedicated_secret_param,
              "PHONY" => ".PHONY: stacks deploy", "PROVISION" => "" }
          end

          def rds_deploy_lines
            "\taws cloudformation deploy --template-file rds.yaml --stack-name $(RDS_STACK) --capabilities CAPABILITY_IAM \\\n" \
              "\t\t--parameter-overrides VpcId=$(VPC) PrivateSubnetIds=$(PRIVATE_SUBNETS) Rehearsal=$(REHEARSAL)\n"
          end

          def dedicated_secret_param
            "\t\tDbSecretArn=$$(aws cloudformation describe-stacks --stack-name $(RDS_STACK) " \
              "--query \"Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue\" --output text) \\"
          end

          def provision_target(plan)
            "# Creates #{plan.infra_name}'s database, role and secret on #{plan.rds_stack}. Run it once; run it again with\n" \
              "# ROTATE=--rotate to change the role's password.  make provision BASTION=i-... [ROTATE=--rotate]\n" \
              "provision:\n\tbash ./provision-database.sh $(BASTION) $(ROTATE)\n\n"
          end
        end
      end
    end
  end
end
