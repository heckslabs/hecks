module Hecks
  module Fuzzing
    module FormCensus
      # The reference-hop forms: a path crossing references, and a reference re-declared under
      # another type. Each reads one aggregate's exported hash.
      module ReferenceForms
        # A given path crossing two references has at least this many segments.
        TWO_HOP_GIVEN_PATH_LENGTH = 3

        module_function

        def two_hop_given?(aggregate)
          FormCensus.commands(aggregate).any? do |verb|
            (verb["givens"] || []).any? { |given| deep_lookup?(given["ast"]) }
          end
        end

        # A `where` whose field crosses two `/` hops, as in `member/sponsor/standing`.
        def multi_hop_where?(aggregate)
          FormCensus.queries(aggregate).any? do |query|
            (query["wheres"] || []).any? { |where| where["field"].to_s.count("/") >= 2 }
          end
        end

        # A command attribute reusing the name of a reference attribute under a non-reference type.
        def revalued_reference?(aggregate)
          references = FormCensus.attributes(aggregate).select { |held| FormCensus.reference?(held) }
                                 .to_set { |held| held["name"].to_s }
          FormCensus.commands(aggregate).any? do |verb|
            (verb["attributes"] || []).any? { |held| references.include?(held["name"].to_s) && !FormCensus.reference?(held) }
          end
        end

        def deep_lookup?(node)
          case node
          when Hash
            return true if node["op"] == "lookup" && Array(node["path"]).size >= TWO_HOP_GIVEN_PATH_LENGTH

            node.each_value.any? { |child| deep_lookup?(child) }
          when Array
            node.any? { |child| deep_lookup?(child) }
          else
            false
          end
        end
      end
    end
  end
end
