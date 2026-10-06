module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # The multi-line pieces of `template.yaml` that depend on the stack's shape: its comments,
          # parameters, the VPC and database it owns, and the Google OAuth wiring. Included into
          # `Stack`; each method is also the value of the template marker of the same name.
          module Blocks
            # Real outbound internet access needs a NAT Gateway: opt-in, the same
            # `google_oauth_present` signal that wires GOOGLE_CLIENT_ID/secret.
            def nat_comment
              file = google_oauth_present ? "lambda/nat_comment_oauth.tmpl" : "lambda/nat_comment_plain.tmpl"
              TextTemplate.render_from(file, self)
            end

            # `google_oauth_present` and `shared` are independent and collected into one array under
            # a single `Parameters:` header, not an if/elsif/else: both can be true at once (a
            # Shared-mode rust_web domain with real Google OAuth).
            def parameters_section
              blocks = []
              blocks << render_block("params_oauth") if google_oauth_present
              blocks << render_block("params_shared") if shared
              return "" if blocks.empty?

              # Indented 2: the blocks dedent to column 0, but these are Parameters: children, which
              # YAML requires indented under it.
              "Parameters:\n#{blocks.join("\n").each_line.map { |line| "  #{line}" }.join}"
            end

            def network_resources
              return "" if shared

              description = compute_description
              yaml = Shared.vpc_and_database_yaml(network, compute_logical_id: logical_id, compute_description: description)
              tail_indent(yaml, "  ")
            end

            def rust_session_secret
              return "" unless rust_web && google_oauth_present

              tail_indent(TextTemplate.render_from("lambda/rust_session_secret.tmpl", self), "  ")
            end

            # `{{resolve:secretsmanager:...}}` dynamic references do not create an implicit
            # CloudFormation dependency on the referenced resource, so Aurora's function waits on
            # its secret and cluster explicitly.
            def aurora_depends
              aurora ? TextTemplate.render_from("lambda/aurora_depends.tmpl", self) : ""
            end

            def db_env
              lines =
                if shared
                  ["DB_HOST: !Ref OwningDatabaseEndpoint", "DB_NAME: #{owner_db_name}",
                   "DB_SECRET_ARN: !Sub \"${OwningDatabaseSecretArn}\""]
                else
                  ["DB_HOST: !GetAtt #{db_ref_id}.Endpoint.Address", "DB_NAME: #{db_name}",
                   "DB_SECRET_ARN: !Sub \"${#{secret_sub}}\""]
                end
              lines.join("\n          ")
            end

            def schema_env
              hecks_schema ? "\n          HECKS_SCHEMA: #{hecks_schema}" : ""
            end

            def rust_oauth_env
              return "" unless rust_web && google_oauth_present

              tail_indent(TextTemplate.render_from("lambda/rust_oauth_env.tmpl", self), "          ", "\n          ")
            end

            def rust_oauth_policy
              return "" unless rust_web && google_oauth_present

              tail_indent(TextTemplate.render_from("lambda/rust_oauth_policy.tmpl", self), "        ")
            end

            def vpc_config
              lines =
                if shared
                  ["SubnetIds: [!Ref OwningSubnetAId, !Ref OwningSubnetBId]", "SecurityGroupIds: [!Ref OwningSecurityGroupId]"]
                else
                  ["SubnetIds: [!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]",
                   "SecurityGroupIds: [!Ref #{logical_id}SecurityGroup]"]
                end
              lines.join("\n        ")
            end

            def web_function_url_output
              return "" unless web_handler_present

              "\n  WebFunctionUrl:\n    Value: !GetAtt #{web_logical_id}Url.FunctionUrl"
            end

            private

            def render_block(name)
              TextTemplate.render_from("lambda/#{name}.tmpl", self).rstrip
            end

            def compute_description
              "#{logical_id} - no inbound (Lambda receives no traffic via its VPC ENI), " \
                "egress rule attached separately below"
            end

            # Prefixes every line after the first with `pad` (the first with `head`), then drops the
            # trailing blank lines: a multi-line value spliced into an indented line of a template.
            def tail_indent(text, pad, head = "")
              text.each_line.with_index.map { |line, i| (i.zero? ? head : pad) + line }.join.rstrip
            end
          end
        end
      end
    end
  end
end
