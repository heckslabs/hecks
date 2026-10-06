require_relative "../../text_template"
require_relative "../../bastion_lines"

module Hecks
  module Projections
    module Deploy
      module Fargate
        class Stack
          # The pieces of the generated Makefile that depend on the stack's shape: how `make deploy`
          # finds the stack's parameters and how `make mint-era` boots it.
          module Recipes
            include BastionLines

            def deploy_command
              file = shared ? "fargate/deploy_shared.tmpl" : "fargate/deploy_plain.tmpl"
              TextTemplate.render_from(file, self).chomp
            end

            # `mint-era` isn't automated for a Shared-mode domain; the other mode runs the same
            # bastion/tunnel/retry/teardown chain `Lambda`'s own generated Makefile uses.
            def mint_era
              file = shared ? "fargate/mint_era_shared.tmpl" : "fargate/mint_era_own.tmpl"
              TextTemplate.render_from(file, self).rstrip
            end

            # @return [Hash{Symbol => String}] the ids `Assembly.apply` fills the template's
            #   sections from
            def assembly_context
              { stack_name: stack_name, vpc_ref: vpc_ref, listener_id: listener_id, alb_id: alb_id,
                distribution_id: distribution_id, db_secret_ref: db_secret_ref }
            end

            # @return [Hash{Symbol => Object}] what a preview stack borrows from this one
            def preview_main
              {
                infra_name: infra_name, stack_name: stack_name, stack_prefix: stack_prefix, region: region,
                cpu: cpu, memory: memory, db_name: shared ? owner_db_name : db_name,
                owner_stack: shared ? owner_stack_name : nil, name: infra_name, port: port,
                **preview_image
              }
            end

            # Renders DB_HOST/DB_NAME/DB_SECRET_ARN, spliced in after the template renders.
            #
            # @param base [String] the indentation of the `# TMPL:db_env` marker line
            def db_env_yaml(base)
              lines = shared ? shared_db_lines : own_db_lines
              lines += ["- Name: HECKS_SCHEMA", "  Value: #{hecks_schema}"] if hecks_schema
              "#{lines.map { |line| "#{base}#{line}" }.join("\n")}\n"
            end

            # Renders one `AWS::IAM::Role` `Policies` entry per cross-domain target, the shape that
            # resource type requires, unlike the bare shorthand
            # `Shared.cross_domain_invoke_policy_yaml` renders for SAM.
            #
            # @param base [String] the indentation of the marker line
            def cross_domain_policy_yaml(base)
              resources = cross_domain_targets.map do |target|
                "#{base}          - !Sub \"arn:aws:lambda:${AWS::Region}:${AWS::AccountId}:function:hecks-#{target.downcase}\""
              end
              "#{[*cross_domain_comment(base), *cross_domain_statement(base), *resources].join("\n")}\n"
            end

            private

            def preview_image
              {
                image: "#{repository_name}:latest", domain: declared_domain_name, web: web,
                wasm_path: "/usr/local/bin/#{domain_name}.wasm", ir_path: "/usr/local/bin/#{domain_name}.ir.json",
                schema: hecks_schema
              }
            end

            def shared_db_lines
              [
                "- Name: DB_HOST", "  Value: !Ref OwningDatabaseEndpoint",
                "- Name: DB_NAME", "  Value: #{db_name_ref || owner_db_name}",
                "- Name: DB_SECRET_ARN", "  Value: !Sub \"${OwningDatabaseSecretArn}\""
              ]
            end

            def own_db_lines
              [
                "- Name: DB_HOST", "  Value: !GetAtt #{db_ref_id}.Endpoint.Address",
                "- Name: DB_NAME", "  Value: #{db_name}",
                "- Name: DB_SECRET_ARN", "  Value: !Sub \"${#{secret_sub}}\""
              ]
            end

            def cross_domain_comment(base)
              ["#{base}# Least-privilege, one ARN per declared `across:` target — see",
               "#{base}# Shared.cross_domain_invoke_policy_yaml's own comment for the full",
               "#{base}# reasoning; this domain's own task role needs the identical grant."]
            end

            def cross_domain_statement(base)
              ["#{base}- PolicyName: CrossDomainInvoke", "#{base}  PolicyDocument:", "#{base}    Version: '2012-10-17'",
               "#{base}    Statement:", "#{base}      - Effect: Allow", "#{base}        Action: lambda:InvokeFunction",
               "#{base}        Resource:"]
            end
          end
        end
      end
    end
  end
end
