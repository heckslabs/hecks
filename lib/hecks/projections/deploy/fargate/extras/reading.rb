module Hecks
  module Projections
    module Deploy
      module Fargate
        module Extras
          # Reads and checks the resource-declaring settings of a world. Extended onto `Extras`,
          # which supplies the key lists.
          module Reading
            private

            def buckets(entries)
              Check.hashes!(entries, "buckets", allowed: BUCKET_KEYS, required: [:id, :name_prefix]).map do |entry|
                {
                  id:           Check.logical_id!(entry[:id], "buckets id"),
                  name_prefix:  Check.resource_name!(entry[:name_prefix], "buckets name_prefix").downcase,
                  public_read:  Check.boolean!(entry.fetch(:public_read, false), "buckets public_read"),
                  cors_origins: Check.strings!(entry.fetch(:cors_origins, []), "buckets cors_origins")
                }
              end
            end

            def secrets(entries)
              Check.hashes!(entries, "generated_secrets", allowed: SECRET_KEYS, required: [:id, :name]).map do |entry|
                {
                  id:          Check.logical_id!(entry[:id], "generated_secrets id"),
                  name:        Check.resource_name!(entry[:name], "generated_secrets name"),
                  description: entry[:description]&.to_s,
                  key:         Check.resource_name!(entry.fetch(:key, "secret"), "generated_secrets key"),
                  length:      Check.integer!(entry.fetch(:length, 64), "generated_secrets length", range: 8..512)
                }
              end
            end

            def session_secret(value)
              return {} if value.nil?

              given = Check.hash!(value, "session_secret", allowed: [:name, :description])
              { name:        given[:name] && Check.resource_name!(given[:name], "session_secret name"),
                description: given[:description]&.to_s }.compact
            end

            def policies(entries, where)
              Check.hashes!(entries, where, allowed: POLICY_KEYS, required: [:name, :statements]).map do |entry|
                statements = Check.hashes!(entry[:statements], "#{where}[#{entry[:name]}] statements",
                                           allowed: STATEMENT_KEYS, required: [:actions, :resources])
                { name:       Check.logical_id!(entry[:name], "#{where} name"),
                  statements: statements.map { |statement| policy_statement(statement, where) } }
              end
            end

            def policy_statement(statement, where)
              {
                effect:    Check.one_of!(statement.fetch(:effect, "Allow"), "#{where} effect", %w[Allow Deny]),
                actions:   Check.strings!(statement[:actions], "#{where} actions", min: 1),
                resources: Check.strings!(statement[:resources], "#{where} resources", min: 1)
              }
            end

            def parameters(map)
              raise ArgumentError, "parameters must be a hash of name to settings, got #{map.inspect}" unless map.is_a?(Hash)

              map.to_h do |name, entry|
                key = Check.logical_id!(name, "parameters name")
                given = Check.hash!(entry, "parameters.#{key}", allowed: PARAMETER_KEYS, required: [:type])
                check_parameter_type!(key, given)
                [key, given.merge(type: given[:type].to_s, no_echo: given[:no_echo] ? true : false)]
              end
            end

            def check_parameter_type!(key, given)
              return if PARAMETER_TYPE.match?(given[:type].to_s)

              raise ArgumentError, "parameters.#{key} type #{given[:type].inspect} is not a CloudFormation parameter type"
            end

            def outputs(map)
              raise ArgumentError, "outputs must be a hash of name to value, got #{map.inspect}" unless map.is_a?(Hash)

              map.to_h do |name, value|
                raise ArgumentError, "outputs.#{name} needs a value" if value.nil?

                [Check.logical_id!(name, "outputs name"), value]
              end
            end
          end
        end
      end
    end
  end
end
