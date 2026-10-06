module Hecks
  module Fuzzing
    module DomainGenerator
      class Builder
        # The shapes a form puts on one aggregate's attributes and rules: lifecycle, query, list,
        # closed set, default and optional attributes.
        module AttributeShapes
          private

          def lifecycle(aggregate)
            return if aggregate["lifecycle"]

            name = aggregate["name"]
            command(aggregate, "Close")
            command(aggregate, "Reopen")
            aggregate["lifecycle"] = { "field" => "status", "default" => "open", "transitions" => [
              { "command" => "Close", "to" => "closed", "from" => ["open"], "requires" => ["command:#{name}.Close"] },
              { "command" => "Reopen", "to" => "open", "from" => ["closed"], "requires" => ["command:#{name}.Reopen"] }
            ] }
          end

          def query(aggregate)
            return if aggregate["queries"].any? { |query| query["name"] == "Listed" }

            where = if aggregate["lifecycle"] || chance?(0.5)
                      lifecycle(aggregate)
                      { "field" => "status", "value" => "open", "requires" => ["lifecycle:#{aggregate["name"]}"] }
                    else
                      priority_where(aggregate)
                    end
            aggregate["queries"] << { "name" => "Listed", "wheres" => [where], "order_by" => aggregate["identity"].first }
          end

          def priority_where(aggregate)
            members = closed_set(aggregate)
            { "field" => "priority.value", "value" => members.first,
              "requires" => ["attribute:#{aggregate["name"]}.priority"] }
          end

          def list_attr(aggregate)
            name = aggregate["name"]
            return if aggregate["attributes"].any? { |attribute| attribute["name"] == "tags" }

            vo(aggregate, "#{name}Tag", "string")
            aggregate["attributes"] << { "name" => "tags", "type" => "#{name}Tag", "list" => true }
            command(aggregate, "Retag", args: [{ "name" => "tags", "type" => "#{name}Tag", "list" => true }],
                                        sets: [{ "target" => "tags", "requires" => ["attribute:#{name}.tags"] }])
          end

          def closed_set(aggregate)
            name = aggregate["name"]
            existing = aggregate["vos"]["#{name}Priority"]
            return existing["members"] if existing

            members = CLOSED_SETS.sample(random: @random)
            vo(aggregate, "#{name}Priority", "closed", members: members)
            aggregate["attributes"] << { "name" => "priority", "type" => "#{name}Priority", "optional" => true }
            command(aggregate, "Prioritize", args: [{ "name" => "priority", "type" => "#{name}Priority" }],
                                             sets: [{ "target" => "priority", "requires" => ["attribute:#{name}.priority"] }])
            members
          end

          def default_attr(aggregate)
            name = aggregate["name"]
            return if aggregate["attributes"].any? { |attribute| attribute["name"] == "score" }

            vo(aggregate, "#{name}Score", "integer")
            aggregate["attributes"] << { "name" => "score", "type" => "#{name}Score", "default" => 0 }
            add_rescore(aggregate, name)
            score_invariant(aggregate, name) if chance?(0.5)
          end

          def add_rescore(aggregate, name)
            score = "attribute:#{name}.score"
            command(aggregate, "Rescore", args: [{ "name" => "amount", "type" => "#{name}Score" }], givens: score_givens(name),
                                          sets: [{ "target" => "score", "to" => "amount", "requires" => [score] }])
          end

          def score_invariant(aggregate, name)
            aggregate["invariants"] << { "label" => "a score is never negative", "expr" => "score.value >= 0",
                                         "requires" => ["attribute:#{name}.score"] }
          end

          # Half the time, a given that a score never drops.
          def score_givens(name)
            return [] unless chance?(0.5)

            [{ "label" => "a score never drops", "expr" => "amount.value >= score.value",
               "requires" => ["attribute:#{name}.score"] }]
          end

          def optional_arg(aggregate)
            name = aggregate["name"]
            return if aggregate["attributes"].any? { |attribute| attribute["name"] == "note" }

            vo(aggregate, "#{name}Note", "string")
            aggregate["attributes"] << { "name" => "note", "type" => "#{name}Note", "optional" => true }
            command(aggregate, "Annotate", args: [{ "name" => "note", "type" => "#{name}Note", "optional" => true }],
                                           sets: [{ "target" => "note", "requires" => ["attribute:#{name}.note"] }])
          end
        end
      end
    end
  end
end
