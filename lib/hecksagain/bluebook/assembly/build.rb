module Hecksagain
  class Bluebook
    class Assembly
      # ONE WAY TO BUILD A CONSTRUCT, for every construct.
      #
      # There used to be a method per category here — `value_object(row)`,
      # `command(row)`, `policy(row)` — each one gathering the same keywords the
      # contract already names. This reads the contract instead, so adding a field
      # to the language and forgetting to assemble it is caught by the coverage gate
      # rather than by nobody.
      #
      # `make` is the only branch, and it is a real one: a construct that became a
      # class is `.declare`d, an instance is `.new`ed. That is the boundary
      # `Query` sits on, and it is a fact about Ruby rather than about the
      # domain.
      module Build
        module_function

        def call(category, row, extra = {})
          contract = Assembly.contract(category)
          keywords = contract.fields.to_h { |keyword, (key, reader)| [keyword, read(reader, row[key])] }

          holder(contract).public_send(contract.make, **keywords.merge(extra))
        end

        def holder(contract)
          contract.holder or raise ArgumentError, "#{contract} holds nothing that can be built"
        end

        # A reader is a Marks method, a list of them, or one of three spellings that
        # need no decoding at all.
        def read(reader, value)
          case reader
          when :plain    then value
          when :identity then value&.to_sym
          when :flag     then value ? true : false
          when Array
            # [:each, reader] maps a list ; [:option, name] reads one named option,
            # which needs its name as well as its value.
            reader.first == :each ? Array(value).map { |held| Marks.public_send(reader.last, held) }
                                  : Marks.option(reader.last, value)
          else Marks.public_send(reader, value)
          end
        end
      end
    end
  end
end
