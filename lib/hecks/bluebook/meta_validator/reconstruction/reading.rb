module Hecks
  module Bluebook
    module MetaValidator
      class Reconstruction
        # Reads rows back out of the runtime: querying one parent's declarations, building a
        # declaration from its contract's field table, and unwrapping the cells.
        module Reading
          private

          # Everything declared in one parent, in the order it was declared. The key
          # is the one the language's own creating command carries, read from Plan.
          def declared(category, parent_id)
            key = @plan.category(category).parent_key
            @runtime.query("Bluebook::#{category}.DeclaredIn", key.to_sym => { value: parent_id.to_s })
          end

          # One declaration, built from the contract's field table. `extra` supplies
          # children and folded objects a row cannot hold on its own.
          def declaration(category, row, extra = {})
            contract = Assembly.contract(category)

            contract.fields.each_with_object({}) do |(_keyword, (key, _build)), out|
              next if extra.key?(key)

              out[key] = read_row(contract.reader(key), key, row)
            end.merge(extra)
          end

          def read_row(spec, key, row)
            case spec
            when nil      then text(row[key])
            when :symbol  then text(row[key])&.to_sym
            when :names   then Array(row[key]).map { |held| text(held[:name]) }
            when Array    then read_shaped(spec, key, row)
            else send(spec, row)
            end
          end

          # `Shapes`'s own readers, called by name. `:each_with_id` also passes the
          # row, since an attribute's type arrives as the ID of what it names.
          def read_shaped(spec, key, row)
            shape, named = spec

            case shape
            when :each         then Array(row[key]).map { |held| send(named, held) }
            when :each_with_id then Array(row[key]).map { |held| send(named, held, row[:id]) }
            when :call         then send(named, row)
            when :from         then pairs(row[named])
            end
          end

          def pairs(with) = Array(with).map { |binding| [text(binding[:key]), text(binding[:value])] }

          # The parts, in the order they went in, because the identity is their join
          # and a join read out of order names a different record.
          def identity_paths(row) = Array(row[:identified_by]).map { |part| text(part[:value]).to_s }

          # The contexts one chapter names itself onto, in the order they were
          # attached — same shape identity_paths reads back, one level up.
          def attached_contexts(row) = Array(row[:attaches_to]).map { |part| text(part[:value]).to_s }

          def provisions(row)
            Array(row[:provides]).map do |part|
              { capability: text(part[:capability]).to_s, key: text(part[:key]).to_s, verb: text(part[:verb]).to_s }
            end
          end

          # Every cell of the meta-domain is a single-field value object, so a row
          # arrives holding Values rather than Strings.
          def text(cell)
            return nil if cell.nil?
            return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

            cell
          end

          # An aggregate's own verbs/asks, told apart from an entity's by `entity_id`;
          # both carry the same parent link. Selecting from an ordered read keeps order.
          def own(category, aggregate_id)
            declared(category, aggregate_id).select { |row| text(row[:entity_id]).to_s == "" }
          end

          # A piece's own verbs/asks: no `DeclaredIn` is keyed by entity, so this
          # queries by `row[:aggregate]` and filters the results by `entity_id`.
          def within(category, row)
            declared(category, text(row[:aggregate]))
              .select { |held| text(held[:entity_id]).to_s == row[:id].to_s }
          end

          # @return [Array<Hash>] the rules held under `key` of `row`, as `rule` reads them
          def rules_in(row, key) = Array(row[key]).map { |held| rule(held) }
        end
      end
    end
  end
end
