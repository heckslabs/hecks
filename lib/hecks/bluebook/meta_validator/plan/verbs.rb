module Hecks
  module Bluebook
    module MetaValidator
      class Plan
        # Sorts a category's commands by what they do: set a field, append to a list, seal the
        # record or carry a reference.
        module Verbs
          private

          # Which arguments of which verbs carry an ID, read straight off the IR.
          def references_in(commands)
            commands.each_with_object({}) do |command, found|
              named = command.attributes.select(&:reference?).map { |attribute| attribute.name.to_s }
              found[command.hecks_name] = named unless named.empty?
            end
          end

          # Every reference argument is dropped, not just the parent link:
          # a reference is not a field.
          def declared_fields(declare)
            return [] unless declare

            declare.attributes.reject(&:reference?).map { |attribute| attribute.name.to_s }
          end

          # list attribute -> the command that appends to it, and how its arguments map.
          def appends_in(commands)
            commands.each_with_object({}) do |command, found|
              Array(command.mutations).each do |mutation|
                next unless mutation.op == :append

                # First wins, not last: Aggregate.Attribute and Aggregate.Reference
                # both extend `attributes`; overwriting would displace one silently.
                found[mutation.target.to_s] ||= Append.new(verb: command.hecks_name, map: mutation.source)
              end
            end
          end

          # The appenders displaced by first-wins in `appends_in`; still verbs
          # the coverage gate must see.
          def alternates_in(commands)
            claimed = Set.new
            commands.flat_map do |command|
              Array(command.mutations).filter_map do |mutation|
                next unless mutation.op == :append

                Append.new(verb: command.hecks_name, map: mutation.source) unless claimed.add?(mutation.target.to_s)
              end
            end
          end

          # Commands that set rather than append. Lifecycle sets two targets at once,
          # so a setter is keyed by its verb and carries every target it writes.
          def setters_in(commands)
            commands.filter_map do |command|
              targets = Array(command.mutations)
                        .select { |mutation| mutation.op == :set }
                        .to_h { |mutation| [mutation.target.to_s, mutation.source.to_s] }
              next if targets.empty?

              Setter.new(verb: command.hecks_name, targets: targets)
            end
          end

          # Commands that change nothing — they exist only to be refused.
          def sealers_in(commands)
            commands.select { |command| Array(command.mutations).empty? }.map(&:hecks_name)
          end
        end
      end
    end
  end
end
