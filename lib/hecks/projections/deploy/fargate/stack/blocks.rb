require_relative "../../text_template"
require_relative "../../shared"

module Hecks
  module Projections
    module Deploy
      module Fargate
        class Stack
          # The multi-line pieces of the template that depend on the stack's shape: its parameters,
          # the VPC and database it owns, and the outputs the bastion reads.
          module Blocks
            # Always true for Fargate: unlike Lambda's opt-in NAT Gateway, a Fargate task always
            # needs internet-facing infra (ALB ingress, ECR/Logs/Secrets egress), so
            # `Shared.vpc_and_database_yaml`'s NAT Gateway is unconditional.
            def network
              Shared::Network.new(shared: shared, db_id: db_id, db_ref_id: db_ref_id, db_name: db_name,
                                  infra_name: infra_name, aurora: aurora, google_oauth_present: true)
            end

            # @return [Array<Hash{Symbol => String}>] the stack-to-bastion contract's outputs
            # @raise [RuntimeError] if a bastion parameter names an output the stack does not
            #   declare
            def stack_outputs
              group = compute_security_group_ref
              outputs = Shared.stack_outputs(network, secret_intrinsic: secret_intrinsic, compute_security_group_ref: group)
              Shared.check_bastion_parameters!(bastion_parameters, outputs)
              outputs
            end

            def bastion_parameters
              Shared.bastion_parameters(shared: shared, google_oauth_present: true)
            end

            def parameters_block
              yaml = [always_params_yaml, oauth_params_yaml, owning_params_yaml, extra_params_yaml].reject(&:empty?).join("\n")
              yaml.empty? ? "" : "Parameters:\n#{yaml.each_line.map { |line| "  #{line}" }.join}"
            end

            def network_resources
              return "" if shared

              compute_id = ids[:compute_prefix]
              description = compute_description
              yaml = Shared.vpc_and_database_yaml(network, compute_logical_id: compute_id, compute_description: description)
              yaml.each_line.with_index.map { |line, i| (i.zero? ? "" : "  ") + line }.join.rstrip
            end

            # Built outside the template so re-indenting it cannot shift this YAML out of sync with
            # SessionSecretRead/env, the same pattern as `Lambda`'s own `OAUTHPOLICY`.
            def oauth_task_policy_yaml
              google_oauth_present ? TextTemplate.render_from("fargate/oauth_task_policy.tmpl", self).rstrip : ""
            end

            def oauth_task_env_yaml
              google_oauth_present ? TextTemplate.render_from("fargate/oauth_task_env.tmpl", self).rstrip : ""
            end

            def oauth_task_policy_marker = oauth_task_policy_yaml.empty? ? "" : "# TMPL:oauth_task_policy"
            def oauth_task_env_marker = oauth_task_env_yaml.empty? ? "" : "# TMPL:oauth_task_env"

            def output_lines
              stack_outputs.map { |output| "#{output[:key]}:\n    Value: #{output[:ref]}" }.join("\n  ")
            end

            private

            def compute_description
              "#{logical_id} - inbound from #{alb_sg_id} only, egress rules attached separately below"
            end

            def always_params_yaml
              TextTemplate.render_from("fargate/always_params.tmpl", self).rstrip
            end

            def oauth_params_yaml
              google_oauth_present ? TextTemplate.render_from("fargate/oauth_params.tmpl", self).rstrip : ""
            end

            def owning_params_yaml
              shared ? TextTemplate.render_from("fargate/owning_params.tmpl", self).rstrip : ""
            end

            def extra_params_yaml
              Settings.parameters_yaml(plan, default_count: desired_count, shared_db_name: owner_db_name).rstrip
            end
          end
        end
      end
    end
  end
end
