module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks every `provides` row of a bluebook: against `Capabilities::CONTRACTS` for a
          # capability the language defines, and against the bluebook itself for one its package
          # declares.
          module Provisions
            private

            # Checks every `provides` row, grouped by the capability it provides.
            def validate_provisions!(bluebook)
              bluebook.provides.group_by(&:capability).each do |capability, rows|
                refuse_repeated_provision_keys!(bluebook, capability, rows)
                if Capabilities.language_defined?(capability)
                  validate_defined_provision!(bluebook, capability, rows)
                else
                  rows.each { |row| validate_package_provision!(bluebook, capability, row) }
                end
              end
            end

            def refuse_repeated_provision_keys!(bluebook, capability, rows)
              repeated = repeated_keys(rows)
              return if repeated.empty?

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} with #{repeated.join(", ")} " \
                               "more than once"
            end

            def repeated_keys(rows)
              counts = rows.map(&:key).tally
              counts.select { |_, count| count > 1 }.keys
            end

            def validate_defined_provision!(bluebook, capability, rows)
              contract = Capabilities::CONTRACTS.fetch(capability)
              refuse_wrong_provision_keys!(bluebook, capability, rows.map { |row| row.key.to_sym }, contract.keys)
              rows.each { |row| validate_provided_verb!(bluebook, capability, row, contract.fetch(row.key.to_sym)) }
            end

            def refuse_wrong_provision_keys!(bluebook, capability, keys, needed)
              return if keys.sort == needed.sort

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} with #{keys.join(", ")}, but " \
                               "#{capability} needs exactly #{needed.join(", ")}"
            end

            def validate_provided_verb!(bluebook, capability, row, kind)
              aggregate_name, member = row.verb.split(".", 2)
              aggregate = bluebook.aggregate(aggregate_name)
              return if aggregate && member && provided_member_names(aggregate, kind).include?(member)

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                               "which names no #{kind} this bluebook declares (spelled \"Aggregate.#{kind.capitalize}\")"
            end

            # A package-declared key must name exactly one thing the bluebook declares; which kind
            # it
            # names is what the reader of the capability is handed (`Capabilities.resolved_value`).
            def validate_package_provision!(bluebook, capability, row)
              kinds = Capabilities.kinds_of(bluebook, row.verb)
              return if kinds.one?

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                               "which #{package_provision_problem(kinds)}"
            end

            def package_provision_problem(kinds)
              return "names #{kinds.join(" and ")} at once; rename one" if kinds.any?

              "names nothing this bluebook declares (spelled \"Aggregate.Command\", \"Aggregate.Query\", " \
                "\"Aggregate.Port.Operation\", \"Aggregate.mark_name\" or \"Aggregate.attribute\")"
            end

            def provided_member_names(aggregate, kind)
              kind == :command ? aggregate.commands.map(&:hecks_name) : aggregate.queries.map(&:name)
            end
          end
        end
      end
    end
  end
end
