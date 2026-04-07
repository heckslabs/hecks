module Hecks
  module Generators
    module Domain
      # Hecks::Generators::Domain::CommandGenerator
      #
      # Generates CQRS command classes with event emission and handler wiring.
      #
      class CommandGenerator < Hecks::Generator
        # Hecks::Generators::Domain::CommandGenerator::InjectionHelpers
        #
        # Extracted helpers for injecting sets, lifecycle status, and lifecycle
        # guard lines into generated command constructor args. Mixed into
        # CommandGenerator to keep the main file under 200 lines.
        #
        # These helpers modify the argument arrays that are passed to +Aggregate.new+
        # in the generated +call+ method, handling:
        # - Explicit field overrides from the DSL's +sets+ declarations
        # - Lifecycle state transitions (setting the status field to the target state)
        # - Lifecycle guard checks (ensuring the aggregate is in the correct state
        #   before allowing a transition)
        # - List append detection (mapping singular command attrs to plural aggregate attrs)
        #
        module InjectionHelpers
          private

          # Injects explicit field overrides from the command's +sets+ declarations
          # into the constructor argument list.
          #
          # Each +sets+ entry replaces any existing argument for that field.
          # Special values:
          # - +:now+ becomes +Time.now.to_s+
          # - Other symbols are emitted as bare references
          # - All other values are +inspect+ed as literals
          #
          # @param args [Array<String>] the mutable argument list to modify in-place
          # @return [void]
          def inject_sets(args)
            return unless @command.sets && !@command.sets.empty?
            @command.sets.each do |field, value|
              args.reject! { |argument| argument.start_with?("#{field}:") }
              if value == :now
                args << "#{field}: Time.now.to_s"
              elsif value.is_a?(Symbol)
                args << "#{field}: #{value}"
              else
                args << "#{field}: #{value.inspect}"
              end
            end
          end

          # Generates lifecycle guard lines that check the aggregate's current state
          # before allowing a command to proceed.
          #
          # If the aggregate has a lifecycle and the command has a +from+ guard defined,
          # generates an +unless+ check that raises +Hecks::Error+ if the current state
          # does not match the required state(s).
          #
          # @param indent [String] the whitespace prefix for each generated line
          # @return [Array<String>] guard lines, or an empty array if no guard applies
          def lifecycle_guard_lines(indent)
            return [] unless @aggregate&.lifecycle
            from_state = @aggregate.lifecycle.from_for(@command.name)
            return [] unless from_state
            field = @aggregate.lifecycle.field
            if from_state.is_a?(Array)
              allowed = from_state.map(&:inspect).join(", ")
              [
                "#{indent}unless [#{allowed}].include?(existing.#{field})",
                "#{indent}  raise #{@domain_module}::Error, \"Cannot #{@command.name}: #{field} must be one of #{from_state.join(', ')}, got '\#{existing.#{field}}'\"",
                "#{indent}end",
              ]
            else
              [
                "#{indent}unless existing.#{field} == \"#{from_state}\"",
                "#{indent}  raise #{@domain_module}::Error, \"Cannot #{@command.name}: #{field} must be '#{from_state}', got '\#{existing.#{field}}'\"",
                "#{indent}end",
              ]
            end
          end

          # Detect when a command appends to a list_of aggregate attr.
          #
          # Two patterns:
          # 1. Singular match: command has "topping" attr matching "toppings" list
          # 2. VO match: command attrs overlap with the value object's attrs
          #
          # @param agg_attr [Hecks::DomainModel::Structure::Attribute] an aggregate attribute to check
          # @return [Hecks::DomainModel::Structure::Attribute, nil] the matching singular command
          #   attribute (pattern 1), or nil
          def find_list_append(agg_attr)
            return nil unless agg_attr.list?
            singular = agg_attr.name.to_s.chomp("s")
            @command.attributes.find { |cmd_attr| cmd_attr.name.to_s == singular }
          end

          # Detect when command attrs match a value object's attrs for list append.
          # Returns the VO and matching command attr names if found.
          #
          # @param agg_attr [Hecks::DomainModel::Structure::Attribute] a list_of aggregate attribute
          # @return [Array, nil] [vo, matching_cmd_attrs] or nil
          def find_vo_append(agg_attr)
            return nil unless agg_attr.list? && @aggregate
            vo = @aggregate.value_objects.find { |value_object| value_object.name == agg_attr.type.to_s }
            return nil unless vo
            vo_attr_names = vo.attributes.map { |attr| attr.name.to_s }
            # Only reject self-referencing _id, not cross-aggregate refs that are VO data
            self_id = @self_ref&.name&.to_s
            cmd_attr_names = @command.attributes.reject { |attr| attr.name.to_s == self_id }.map { |attr| attr.name.to_s }
            matching = vo_attr_names & cmd_attr_names
            matching.size >= vo_attr_names.size ? [vo, matching] : nil
          end

          # Injects the lifecycle target state into the constructor argument list.
          #
          # If the aggregate has a lifecycle and the command triggers a state transition,
          # replaces any existing argument for the lifecycle field with the target state.
          #
          # @param args [Array<String>] the mutable argument list to modify in-place
          # @return [void]
          def inject_lifecycle_status(args)
            return unless @aggregate&.lifecycle
            target = @aggregate.lifecycle.target_for(@command.name)
            # For create commands, use the lifecycle default when no transition is defined
            target ||= @aggregate.lifecycle.default if @is_create
            return unless target
            field = @aggregate.lifecycle.field
            args.reject! { |argument| argument.start_with?("#{field}:") }
            args << "#{field}: \"#{target}\""
          end
        end

          # Returns the aggregate's non-reserved attributes.
          def agg_attrs
            return [] unless @aggregate
            @aggregate.attributes.reject { |attr| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(attr.name.to_s) }
          end

          # Builds args for creating a new aggregate from scratch.
          def create_constructor_args
            args = agg_attrs.each_with_object([]) do |agg_attr, parts|
              cmd_attr = @command.attributes.find { |cmd_a| cmd_a.name == agg_attr.name }
              if cmd_attr
                parts << "#{agg_attr.name}: #{agg_attr.name}"
              elsif (vo_match = find_vo_append(agg_attr))
                vo, matching_attrs = vo_match
                vo_args = matching_attrs.map { |attr| "#{attr}: #{attr}" }.join(", ")
                parts << "#{agg_attr.name}: [#{vo.name}.new(#{vo_args})]"
              elsif (append = find_list_append(agg_attr))
                vo_class = agg_attr.type
                parts << "#{agg_attr.name}: [#{vo_class}.new(name: #{append.name})]"
              end
            end
            (@command.references || []).each do |ref|
              args << "#{ref.name}: #{ref.name}"
            end
            inject_sets(args)
            inject_lifecycle_status(args)
            args
          end

          # Builds args for updating an existing aggregate.
          def update_constructor_args
            parts = ["id: existing.id"]
            agg_attrs.each do |agg_attr|
              cmd_attr = @command.attributes.find { |cmd_a| cmd_a.name == agg_attr.name }
              if cmd_attr
                parts << "#{agg_attr.name}: #{agg_attr.name}"
              elsif (vo_match = find_vo_append(agg_attr))
                vo, matching_attrs = vo_match
                vo_args = matching_attrs.map { |attr| "#{attr}: #{attr}" }.join(", ")
                parts << "#{agg_attr.name}: existing.#{agg_attr.name} + [#{vo.name}.new(#{vo_args})]"
              elsif (append = find_list_append(agg_attr))
                vo_class = agg_attr.type
                cmd_name = append.name
                parts << "#{agg_attr.name}: existing.#{agg_attr.name} + [#{vo_class}.new(name: #{cmd_name})]"
              else
                parts << "#{agg_attr.name}: existing.#{agg_attr.name}"
              end
            end
            (@command.references || []).each do |ref|
              parts << "#{ref.name}: #{ref.name}"
            end
            inject_sets(parts)
            inject_lifecycle_status(parts)
            parts
          end
      end
    end
  end
end
