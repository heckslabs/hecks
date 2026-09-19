module Hecks
  module Bluebook
    class Assembly
      # One way to build a construct, for every construct.
      #
      # Not a method per category — `value_object(row)`, `command(row)`,
      # `policy(row)`, each gathering the same keywords the contract already
      # names. This reads the contract instead, so adding a field to the
      # language and forgetting to assemble it is caught by the coverage gate
      # rather than by nobody.
      #
      # `make` is the only branch, and it is a real one: a construct that became a
      # class is `.declare`d, an instance is `.new`ed. That is the boundary
      # `Query` sits on, and it is a fact about Ruby rather than about the
      # domain.
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

        # A reader is a Marks method, a list of them, or one of three spellings that
        # need no decoding at all.
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
          when Array
            # [:each, reader] maps a list ; [:option, name] reads one named option,
            # which needs its name as well as its value.
            if reader.first == :each
              Array(value).map { |held| Marks.public_send(reader.last, held) }
            else
              Marks.option(reader.last, value)
            end
          else Marks.public_send(reader, value)
          end
        end
      end
    end
  end
end
