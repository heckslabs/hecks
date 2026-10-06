module Hecks
  module Bluebook
    class Assembly
      # Builds any construct from its declared row by reading its `Assembly.contract`.
      #
      # A construct that is a class is `.declare`d; an instance is `.new`ed.
      module Build
        module_function

        # Builds one construct from its declared row, reading which keywords it takes
        # and how to read each one off `Assembly.contract(category)`.
        #
        # @param category [String] the contract's category name, such as `"Aggregate"`
        #   or `"Command"`
        # @param row [Hash{Symbol => Object}] the construct's own declared row
        # @param extra [Hash{Symbol => Object}] keywords the caller supplies directly,
        #   such as already-built children the contract itself cannot derive
        # @return [Object] the built construct: an instance for a category whose
        #   `make` is `:new`, or a class for one whose `make` is `:declare`
        def call(category, row, extra = {})
          contract = Assembly.contract(category)
          keywords = contract.fields.to_h { |keyword, (key, reader)| [keyword, read(reader, row[key])] }

          holder(contract).public_send(contract.make, **keywords, **extra)
        end

        # Resolves the class or module a contract's construct is built through.
        #
        # @param contract [Bluebook::Assembly::Contract] the category's field contract
        # @return [Module] the holder that answers `contract.make` (`.new` or `.declare`)
        # @raise [ArgumentError] if the contract names no holder to build through
        def holder(contract)
          contract.holder or raise ArgumentError, "#{contract} holds nothing that can be built"
        end

        # Reads one value through a contract reader.
        #
        # @param reader [Symbol, Array, nil] the contract field's reader: `:plain`,
        #   `:identity`, `:flag`, `[:each, marks_method]`, `[:option, name]`, or a bare
        #   `Marks` method name
        # @param value [Object] the raw declared value to read
        # @return [Object] the value read through `reader`
        def read(reader, value)
          case reader
          when :plain    then value
          when :identity then value&.to_sym
          when :flag     then value ? true : false
          when Array then read_marked(reader, value)
          else Marks.public_send(reader, value)
          end
        end

        # `[:option, name]` needs its name as well as its value.
        #
        # @param reader [Array] `[:each, marks_method]` or `[:option, name]`
        # @param value [Object] the raw declared value to read
        # @return [Object] the value read through the `Marks` method `reader` names
        def read_marked(reader, value)
          return Marks.option(reader.last, value) unless reader.first == :each

          Array(value).map { |held| Marks.public_send(reader.last, held) }
        end
      end
    end
  end
end
