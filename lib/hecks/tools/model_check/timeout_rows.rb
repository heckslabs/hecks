module Hecks
  module Tools
    module ModelCheck
      # Reads the timeout rows a bluebook declares: the members of the value object that prices
      # its waits, as the stall watch reads them. `ModelCheck` extends it.
      module TimeoutRows
        # The value object whose members are the timeout rows.
        SHAPE = "StallKind".freeze

        # @param declaration [Bluebook::Declaration] a booted bluebook
        # @param shape [String] the name of the value object that holds the rows
        # @return [Array<Hash{Symbol => Object}>, nil] each row's attributes, or nil for a bluebook
        #   that declares no such value object
        def timeout_rows(declaration, shape: SHAPE)
          holders = declaration.aggregates.flat_map(&:value_objects).select { |object| object.hecks_name == shape }
          return if holders.empty?

          holders.flat_map { |holder| Array(holder.members).map { |row| row.to_h.transform_keys(&:to_sym) } }
        end
      end
    end
  end
end
