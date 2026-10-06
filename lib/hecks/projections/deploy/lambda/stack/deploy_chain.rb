module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # The `deploy:` target of the generated Makefile: the builds, the pre-deploy era bridge
          # and the `sam deploy` chain. Included into `Stack`; each method is also the value of the
          # template marker of the same name.
          module DeployChain
            OWNER_LOOKUPS = {
              "OWNER_VPC_ID"        => "VpcId",
              "OWNER_SUBNET_A_ID"   => "PrivateSubnetAId",
              "OWNER_SUBNET_B_ID"   => "PrivateSubnetBId",
              "OWNER_SG_ID"         => "FunctionSecurityGroupId",
              "OWNER_DB_HOST"       => "DatabaseEndpoint",
              "OWNER_DB_SECRET_ARN" => "DatabaseSecretArn"
            }.freeze
            OWNING_OVERRIDES = "OwningVpcId=$$OWNER_VPC_ID OwningSubnetAId=$$OWNER_SUBNET_A_ID " \
                               "OwningSubnetBId=$$OWNER_SUBNET_B_ID OwningSecurityGroupId=$$OWNER_SG_ID " \
                               "OwningDatabaseEndpoint=$$OWNER_DB_HOST OwningDatabaseSecretArn=$$OWNER_DB_SECRET_ARN".freeze

            # The builds `make deploy` runs, which depend on which Lambdas the stack has.
            def build_recipe
              file =
                if dispatch_none then "build_dispatch_none"
                elsif pg_version then "build_pg"
                elsif web_handler_present then "build_web"
                else "build_plain"
                end
              TextTemplate.render_from("lambda/#{file}.tmpl", self)
            end

            # The transaction-safety gap, closed for the case that actually matters: `sam deploy` is
            # what flips this Lambda's own HECKS_DOMAIN/HECKS_SCHEMA env vars live, so the era
            # history is bridged before it, as well as after. Tab-indented for a Makefile recipe.
            def predeploy_bridge
              return "" if shared

              bridge = TextTemplate.render_from("lambda/predeploy_bridge.tmpl", self)
              bridge.each_line.map { |line| "\t#{line}" }.join.rstrip
            end

            # Google OAuth newly added to an existing stack would deadlock this bridge:
            # PublicSubnetId/BastionSubnetId don't exist on the live stack until the upcoming
            # `sam deploy` creates them, so the pre-check's own `mint-era` call would hand
            # bastion.yaml an empty Subnet::Id and CloudFormation would refuse it before
            # `sam deploy` ever runs. Skip the bridge in exactly that case; the unconditional
            # `mint-era` call at the end of `deploy:` still covers it afterward.
            def predeploy_bridge_shell
              file = google_oauth_present ? "predeploy_bridge_oauth" : "predeploy_bridge_plain"
              TextTemplate.render_from("lambda/#{file}.tmpl", self).rstrip
            end

            def deploy_recipe_lines
              lines = []
              lines << "$(MAKE) sync-google-oauth" if google_oauth_present
              lines << shared_lookup_note if shared
              (lines + deploy_shell_chain).map { |line| "\t#{line}" }.join("\n")
            end

            private

            def shared_lookup_note
              "@echo \"Looking up #{owner_stack_name}'s shared VpcId/PrivateSubnetAId/PrivateSubnetBId/" \
                "FunctionSecurityGroupId/DatabaseEndpoint/DatabaseSecretArn outputs to pass as $(STACK)'s " \
                "Owning* parameters...\""
            end

            # `@` (Make's "don't echo" prefix) is only meaningful on the chain's true first line, so
            # lines are built unprefixed and `@` is added once, right before joining.
            def deploy_shell_chain
              chain = owner_lookup_lines + sam_deploy_lines
              return chain unless chain.first&.include?("=$$(")

              ["@#{chain.first}"] + chain.drop(1)
            end

            def owner_lookup_lines
              return [] unless shared

              OWNER_LOOKUPS.map do |variable, key|
                "#{variable}=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} " \
                  "--query \"Stacks[0].Outputs[?OutputKey=='#{key}'].OutputValue\" --output text); \\"
              end
            end

            # `google_oauth_present` and `shared` are independent facts, not alternatives: an elsif
            # would silently drop Owning* overrides whenever OAuth is also present.
            def sam_deploy_lines
              overrides = shared ? OWNING_OVERRIDES : nil
              return oauth_deploy_lines(overrides) if google_oauth_present

              [shared ? "sam deploy --parameter-overrides #{overrides}" : "sam deploy"]
            end

            def oauth_deploy_lines(overrides)
              extra = overrides ? " #{overrides}" : ""
              plain = overrides ? " --parameter-overrides #{overrides}" : ""
              [
                web_url_lookup,
                "if [ -n \"$$WEB_URL\" ]; then \\",
                "\tsam deploy --parameter-overrides WebRedirectBaseUrl=\"$$WEB_URL\"#{extra}; \\",
                "else \\",
                "\tsam deploy#{plain}; \\",
                "fi"
              ]
            end

            def web_url_lookup
              function = rust_web ? stack_name : "#{stack_name}-web"
              "WEB_URL=$$(aws lambda get-function-url-config --function-name #{function} --query FunctionUrl " \
                "--output text 2>/dev/null | sed 's:/$$::'); \\"
            end
          end
        end
      end
    end
  end
end
