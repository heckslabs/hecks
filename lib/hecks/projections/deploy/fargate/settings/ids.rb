module Hecks
  module Projections
    module Deploy
      module Fargate
        module Settings
          # The logical ids and the AWS names of a stack's resources, derived from the stack and
          # overridable by the world. Extended onto `Settings`, which supplies the role lists.
          module Ids
            private

            def logical_ids(overrides, base)
              given = overrides ? Check.hash!(overrides, "logical_ids", allowed: id_keys) : {}
              derived = derived_ids(base)
              given.each { |role, id| derived[role] = Check.logical_id!(id, "logical_ids #{role}") }
              derived.freeze
            end

            def derived_ids(base)
              derived = ID_ROLES.to_h { |role, suffix| [role, suffix ? "#{base[:logical_id]}#{suffix}" : base[:logical_id]] }
              derived.merge!(FIXED_IDS)
              derived[:database_prefix] = base[:db_id]
              derived[:compute_prefix] = base[:logical_id]
              derived
            end

            def id_keys
              ID_ROLES.keys + FIXED_IDS.keys + [:database_prefix, :compute_prefix]
            end

            def names(overrides, base)
              given = overrides ? Check.hash!(overrides, "names", allowed: NAME_ROLES) : {}
              stack = base[:stack_name]
              derived = {
                cluster: stack, log_group: "/ecs/#{stack}", service: stack, alb: "#{stack}-alb",
                family: base[:infra_name], db_secret_policy: "DbSecretRead"
              }
              given.each { |role, name| derived[role] = named(role, name) }
              derived.freeze
            end

            def named(role, value)
              return Check.resource_name!(value, "names #{role}") unless role == :alb_security_group_description

              text = value.to_s
              return text if text.match?(/\A[\x20-\x7e]{1,255}\z/)

              raise ArgumentError,
                    "names #{role} must be 1 to 255 printable ASCII characters (EC2 rejects anything else), got #{value.inspect}"
            end
          end
        end
      end
    end
  end
end
