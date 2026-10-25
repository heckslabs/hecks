module Hecks
  module Bluebook
    module Expression
      module AstReader
        # Reads the nodes that take a block (`all?`/`any?`/`none?`, `find`, `sum`) back from their
        # `"op"`-tagged JSON.
        module Blocks
          module_function

          # @param json [Hash] a resolver node
          # @return [Object, nil] the block-taking node it spells, or `nil` for any other op
          def read(json)
            case json["op"]
            when "block_predicate" then block_predicate(json)
            when "find" then find(json)
            when "sum" then sum(json)
            end
          end

          # @return [Resolver::BlockPredicate] the `all?`, `any?` or `none?` node
          def block_predicate(json)
            Resolver::BlockPredicate.new(mode: json["mode"].to_sym, receiver: AstReader.receiver(json), param: json["param"],
                                         predicate: AstReader.read_bool(json["predicate"]))
          end

          # @return [Resolver::Find] the `find` node, with the path it projects through
          def find(json)
            Resolver::Find.new(receiver: AstReader.receiver(json), param: json["param"],
                               predicate: AstReader.read_bool(json["predicate"]), path: json["path"])
          end

          # @return [Resolver::Sum] the `sum` node
          def sum(json)
            Resolver::Sum.new(receiver: AstReader.receiver(json), param: json["param"],
                              predicate: AstReader.read_bool(json["predicate"]))
          end
        end
      end
    end
  end
end
