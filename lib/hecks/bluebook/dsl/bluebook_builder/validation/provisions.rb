module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks every `provides` row of a chapter against `Capabilities::CONTRACTS`.
          module Provisions
            private

            # Checks every `provides` row against `Capabilities::CONTRACTS`.
            def validate_provisions!(bluebook)
              bluebook.provides.group_by(&:capability).each do |capability, rows|
                validate_provision!(bluebook, capability, rows)
              end
            end

            def validate_provision!(bluebook, capability, rows)
              contract = Capabilities::CONTRACTS.fetch(capability) do
                raise Malformed, "#{bluebook.name} provides #{capability.inspect}, which is no capability the " \
                                 "language knows — known: #{Capabilities::CONTRACTS.keys.sort.join(", ")}"
              end

              refuse_wrong_provision_keys!(bluebook, capability, rows, contract)
              rows.each { |row| validate_provided_verb!(bluebook, capability, row, contract.fetch(row.key.to_sym)) }
            end

            def refuse_wrong_provision_keys!(bluebook, capability, rows, contract)
              keys = rows.map { |row| row.key.to_sym }
              required = Capabilities.required_keys(capability)
              return if provision_keys_valid?(keys, required, contract.keys)

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} with #{keys.join(", ")}, but " \
                               "#{capability} needs #{provision_keys_phrase(required, contract.keys - required)}"
            end

            def provision_keys_valid?(keys, required, allowed)
              (keys - allowed).empty? && (required - keys).empty? && keys.uniq.size == keys.size
            end

            def provision_keys_phrase(required, optional)
              return "exactly #{required.join(", ")}" if optional.empty?

              "#{required.join(", ")} and may add #{optional.join(", ")}"
            end

            def validate_provided_verb!(bluebook, capability, row, kind)
              return validate_provided_port_operation!(bluebook, capability, row) if kind == :port_operation
              return validate_provided_mark!(bluebook, capability, row) if kind == :mark

              aggregate_name, member = row.verb.split(".", 2)
              aggregate = bluebook.aggregate(aggregate_name)
              return if aggregate && member && provided_member_names(aggregate, kind).include?(member)

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                               "which names no #{kind} this chapter declares (spelled \"Aggregate.#{kind.capitalize}\")"
            end

            # Only the verb's shape and aggregate are checkable here: the port is declared
            # in the hecksagon, which attaches after the chapter is built. `Registry#verify!`
            # checks the operation.
            def validate_provided_port_operation!(bluebook, capability, row)
              aggregate_name, port, operation = row.verb.split(".", 3)
              return if bluebook.aggregate(aggregate_name) && port && operation && !operation.include?(".")

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                               "which is not spelled \"Aggregate.Port.Operation\" over an aggregate this chapter declares"
            end

            # A mark verb is spelled "Aggregate.mark_name" and must name a mark declared on that
            # aggregate's lifecycle.
            def validate_provided_mark!(bluebook, capability, row)
              aggregate_name, mark = row.verb.split(".", 2)
              aggregate = bluebook.aggregate(aggregate_name)
              return if aggregate && mark && aggregate.lifecycle&.marked(mark)

              raise Malformed, "#{bluebook.name} provides #{capability.inspect} #{row.key}: #{row.verb.inspect}, " \
                               "which names no lifecycle mark this chapter declares (spelled " \
                               "\"Aggregate.mark_name\", with `mark :mark_name, ...` in that aggregate's lifecycle)"
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
