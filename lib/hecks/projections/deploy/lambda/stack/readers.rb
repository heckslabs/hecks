module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # The ids and references derived from a stack's declared facts. Each method is also the
          # value of the template marker of the same name.
          module Readers
            def db_id = "#{logical_id.delete_suffix("Function")}Db"

            # Aurora splits the database into a DBCluster plus DBInstance(s), so every
            # `.Endpoint.Address`/`.MasterUserSecret` reference has to point at the cluster, not
            # `db_id`, when Aurora is chosen.
            def db_ref_id = aurora ? "#{db_id}Cluster" : db_id

            # Aurora uses a self-managed secret (ManageMasterUserPassword rotation would break a
            # Lambda's static Environment); plain RDS uses its own MasterUserSecret attribute.
            # `secret_sub` is for `!Sub "${...}"` interpolation; `secret_intrinsic` is the same fact
            # as a bare value.
            def secret_sub = aurora ? "#{db_id}Secret" : "#{db_ref_id}.MasterUserSecret.SecretArn"
            def secret_intrinsic = aurora ? "!Ref #{db_id}Secret" : "!GetAtt #{db_ref_id}.MasterUserSecret.SecretArn"

            # Shared mode has no `secret_sub` of its own; `OwningDatabaseSecretArn` (the template's
            # Parameter) is already a bare ARN string.
            def db_secret_ref = shared ? "OwningDatabaseSecretArn" : secret_sub

            def host_dir = File.join(root, "rust", "host")
            def wasm_path = File.join(root, "rust", "dist", "#{domain_name}.wasm")
            def ir_path = File.join(root, "rust", "dist", "#{domain_name}.ir.json")
            def infra_name_literal = infra_name.inspect
            def declared_domain_literal = declared_domain_name.inspect
            def schema_setting = hecks_schema ? ", schema: #{hecks_schema.inspect}" : ""
            def function_url_auth = rust_web ? "NONE" : "AWS_IAM"
            def oauth_function_id = rust_web ? logical_id : web_logical_id

            def network
              Shared::Network.new(shared: shared, db_id: db_id, db_ref_id: db_ref_id, db_name: db_name,
                                  infra_name: infra_name, aurora: aurora, google_oauth_present: google_oauth_present)
            end

            # The stack-to-bastion contract: one table `template.yaml`'s Outputs, `bastion.yaml`'s
            # Parameters and the Makefile's overrides all read from.
            def stack_outputs
              group = "!Ref #{logical_id}SecurityGroup"
              outputs = Shared.stack_outputs(network, secret_intrinsic: secret_intrinsic, compute_security_group_ref: group)
              Shared.check_bastion_parameters!(bastion_parameters, outputs)
              outputs
            end

            def bastion_parameters
              Shared.bastion_parameters(shared: shared, google_oauth_present: google_oauth_present)
            end

            def output_lines
              stack_outputs.map { |output| "#{output[:key]}:\n    Value: #{output[:ref]}" }.join("\n  ")
            end
          end
        end
      end
    end
  end
end
