module Hecks
  module Fuzzing
    module DomainGenerator
      class Builder
        # The shapes a form puts on one aggregate's identity and entities.
        module Shapes
          private

          def composite_id(aggregate)
            return if aggregate["identity"].size > 1

            name = aggregate["name"]
            vo(aggregate, "#{name}Branch", "string")
            vo(aggregate, "#{name}Number", "positive")
            aggregate["identity"] = %w[branch number]
            swap_code_attribute!(aggregate, name)
            open = creating(aggregate)
            open["args"] = branch_number_attributes(name)
            open["sets"] = [{ "target" => "branch" }, { "target" => "number" }]
            aggregate["vos"].delete("#{name}Code")
          end

          def swap_code_attribute!(aggregate, name)
            aggregate["attributes"].reject! { |attribute| attribute["name"] == "code" }
            aggregate["attributes"].unshift(*branch_number_attributes(name))
          end

          def branch_number_attributes(name)
            [{ "name" => "branch", "type" => "#{name}Branch" }, { "name" => "number", "type" => "#{name}Number" }]
          end

          def entity(aggregate, composite: false, lifecycle: false)
            name = next_entity_name(aggregate)
            return unless name

            parts = composite ? %w[batch sequence] : ["sequence"]
            types = entity_value_objects(aggregate, name, composite)
            list  = "#{name.downcase}s"

            aggregate["attributes"] << entity_list_attribute(aggregate["name"], name, list)
            aggregate["entities"] << entity_piece(aggregate["name"], name, parts, types, lifecycle)
            add_entity_command(aggregate, name, list, parts, types)
          end

          def next_entity_name(aggregate)
            (ENTITY_NAMES - aggregate["entities"].map { |entity| entity["name"] }).first
          end

          def entity_list_attribute(owner, name, list)
            { "name" => list, "type" => name, "list" => true, "requires" => ["entity:#{owner}.#{name}"] }
          end

          def add_entity_command(aggregate, name, list, parts, types)
            owner = aggregate["name"]
            command(aggregate, "Add#{name}",
                    args:  parts.map { |part| { "name" => part, "type" => types[part] } },
                    sets:  [{ "target" => list, "append" => parts.to_h { |part| [part, part] },
                              "requires" => ["attribute:#{owner}.#{list}", "entity:#{owner}.#{name}"] }],
                    emits: ["#{owner}#{name}Added"])
          end

          # Declares the value objects an entity's attributes use; answers part name => type name.
          def entity_value_objects(aggregate, name, composite)
            vo(aggregate, "#{name}Sequence", "positive")
            vo(aggregate, "#{name}Batch", "string") if composite
            vo(aggregate, "#{name}Label", "string")
            { "sequence" => "#{name}Sequence", "batch" => "#{name}Batch" }
          end

          # Qualified by the owner, not just the entity name: `ENTITY_NAMES`
          # is shared across aggregates, so two could otherwise both emit a
          # bare "LineAdded" with different shapes.
          def entity_piece(owner, name, parts, types, lifecycle)
            piece = { "name" => name, "identity" => parts, "requires" => [],
                      "attributes" => parts.map { |part| { "name" => part, "type" => types[part] } } +
                                      [{ "name" => "label", "type" => "#{name}Label", "optional" => true }],
                      "lifecycle" => nil,
                      "commands" => [{ "name" => "Label", "creates" => false, "references" => [],
                                       "args" => [{ "name" => "label", "type" => "#{name}Label" }], "givens" => [],
                                       "sets" => [{ "target" => "label" }], "emits" => ["#{owner}#{name}Labeled"] }] }
            settle(piece, owner, name) if lifecycle || chance?(0.2)
            piece
          end

          # Gives an entity a `Settle` command and the lifecycle it drives.
          def settle(piece, owner, name)
            piece["commands"] << { "name" => "Settle", "creates" => false, "references" => [], "args" => [], "givens" => [],
                                   "sets" => [], "emits" => ["#{owner}#{name}Settled"] }
            piece["lifecycle"] = { "field" => "state", "default" => "pending",
                                   "transitions" => [{ "command" => "Settle", "to" => "settled", "from" => ["pending"],
                                                       "requires" => ["command:#{owner}.#{name}.Settle"] }] }
          end
        end
      end
    end
  end
end
