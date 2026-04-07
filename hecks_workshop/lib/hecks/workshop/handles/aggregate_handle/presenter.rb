module Hecks
  class Workshop
    class AggregateHandle
    # Hecks::Workshop::AggregateHandle::Presenter
    #
    # Presentation methods for AggregateHandle: describe (detailed summary with
    # attributes, VOs, entities, commands, validations, invariants, policies,
    # queries, scopes, subscribers, and specifications), inspect (one-line),
    # preview (generated code), valid?/errors (validation), and the type_label
    # helper for formatting types.
    #
    # Mixed into AggregateHandle to separate display logic from builder logic.
    #
    module Presenter
      # Print a detailed summary of the aggregate's structure.
      #
      # Builds the aggregate from its builder and prints all sections:
      # attributes, value objects, entities, commands, validations,
      # invariants, policies, queries, scopes, subscribers, and specifications.
      #
      # @return [nil]
      def describe
        puts Hecks::AggregateDescriber.describe_lines(@builder.build).join("\n")
        nil
      end

      # Print the generated Ruby code for this aggregate.
      #
      # Uses the AggregateGenerator to produce the code that would be
      # written to a gem for this aggregate, and prints it to stdout.
      #
      # @return [nil]
      def preview
        agg = @builder.build
        domain_module = @domain_module || "Domain"
        gen = Generators::Domain::AggregateGenerator.new(agg, domain_module: domain_module)
        puts gen.generate
        nil
      end

      # Check whether this aggregate has no validation errors.
      #
      # @return [Boolean] true if there are no errors
      def valid?
        errors.empty?
      end

      # Return validation errors relevant to this aggregate.
      #
      # Validates the entire domain via the parent workshop and filters
      # errors to only those mentioning this aggregate's name.
      #
      # @return [Array<String>] error messages related to this aggregate
      def errors
        return [] unless @workshop
        domain = @workshop.to_domain
        validator = Validator.new(domain)
        return [] if validator.valid?
        validator.errors.select { |e| e.include?(@name) }
      end

      # Return a compact string representation of this aggregate handle.
      #
      # @return [String] e.g. "#<Pizza (3 attributes, 2 commands)>"
      def inspect
        "#<#{@name} (#{attributes.size} attributes, #{commands.size} commands)>"
      end

      private

      # Format a type for display in REPL output.
      #
      # Handles plain types (returns their +to_s+), list types
      # ({list: String} -> "list_of(String)"), and reference types
      # ({reference: "Order"} -> "reference_to(Order)").
      #
      # @param type [Class, Hash] the type to format
      # @return [String] human-readable type label
      def type_label(type)
        case type
        when Hash
          if type[:list]
            "list_of(#{type[:list]})"
          elsif type[:reference]
            "reference_to(#{type[:reference]})"
          else
            type.to_s
          end
        else
          type.to_s
        end
      end
    end
    end
  end
end
