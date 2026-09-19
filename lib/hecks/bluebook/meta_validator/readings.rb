module Hecks
  module Bluebook
    module MetaValidator
      # The parts of a bluebook the walk cannot read by name alone.
      #
      # The language now spells its fields exactly as the IR spells them, so the
      # judge reads almost everything straight through: `command.givens`,
      # `value_object.invariants`, `read_model.aggregate_heads`. What remains here
      # is not naming drift — it is places where the IR's shape differs from the
      # language's, and no amount of renaming would close that:
      #
      #   transitions    one declaration expands to several rows, because `from`
      #                  may be a list of states
      #   value_objects  the IR holds objects ; the language holds their names
      #   normalisations not on the bluebook at all — they come from the canonical
      #                  form table the expression grammar keeps
      #   members        plain hashes, one Member root per row, pairs per entry
      #   lifecycle      one IR object feeding two separate fields
      #
      # Everything in this file is a difference in shape. If something here is
      # only a difference in name, it is in the wrong file: rename the language.
      module Readings
        # A list the walk is about to offer, as rows it can shape into dispatches.
        #
        # From the table. This was nine hand-written cases keyed "Category.list", and
        # every one of them was a fact `Assembly::Contracts` is the right place to
        # keep: which shaper turns this list into rows. A list with no shaper reads
        # straight off the node, which is most of them.
        #
        # @param category [String] the node's own category name, such as `"Command"`
        # @param list_name [String, Symbol] the list's own name, such as `"mutations"`
        # @param node [Object] the built IR node currently walked — an `Aggregate`,
        #   `Command`, `Entity`, `Query`, `ValueObject`, `ReadModel`, `Policy`,
        #   `ProcessManager`, `Handler`, or similar `Hecks::IR`-including construct
        # @return [Array<Object>] `list_name`'s own elements, shaped into rows when
        #   `category` declares a shaper, or read straight off `node` otherwise
        def rows_for(category, list_name, node)
          shaper = Assembly.contract(category).shaper(list_name)
          return Array(node.public_send(list_name)) unless shaper

          public_send(shaper, node)
        end

        # A where-clause is read through its own to_h, which is where the IR spells a
        # symbol argument as ":ceiling". Reading the object instead lost the colon,
        # and nothing downstream could tell an argument from a literal of the same
        # name.
        #
        # @param node [Bluebook::ReadModel, Bluebook::Query] the built IR node to read
        # @return [Array<Hash>] one `to_h` per where-clause `node` declares
        def where_rows(node) = Array(node.wheres).map(&:to_h)

        # The language holds a value object's name here ; the IR holds the object.
        #
        # @param node [Bluebook::Aggregate] the built aggregate to read
        # @return [Array<Hash{Symbol => String}>] `{name:}` for every value object `node` owns
        def value_object_names(node) = node.value_objects.map { |shape| { name: shape.hecks_name } }

        # An identity is a list of parts, so it is offered one part at a time — the
        # same way attributes and transitions are. The IR holds the paths ; the
        # language holds a row per path, and the order between them is the whole
        # meaning, because the identity is their join.
        #
        # @param node [Bluebook::Aggregate, Bluebook::Entity] the built IR node to read
        # @return [Array<Hash{Symbol => String}>] `{value:}`, one per identity path, in order
        def identity_rows(node) = node.identity_paths.map { |path| { value: path } }

        # Through to_h, which is where Bluebook.render_value spells a symbol argument as
        # ":source". The raw with_spec lost the colon, and a binding that reads an
        # argument became indistinguishable from one carrying a literal string.
        #
        # @param node [Bluebook::DispatchSpec] the built dispatch to read
        # @return [Array<Hash{Symbol => Object}>] `{key:, value:}` rows, one per binding
        def with_spec_rows(node) = pair_rows(node.to_h[:with_spec])

        # The same read, one level in — `compensates` folds `DispatchSpec`
        # into the language's own `compensates_command_name`/
        # `compensates_with_spec` (`Assembly::Contracts`' own comment on
        # "Dispatch"), so its own with_spec pairs live nested one hash
        # down from where `with_spec_rows` looks. `&.dig(...)` — no
        # compensation at all is not an error, it is `pair_rows(nil)`, empty.
        #
        # @param node [Bluebook::DispatchSpec] the built dispatch to read
        # @return [Array<Hash{Symbol => Object}>] `{key:, value:}` rows, one per binding of
        #   `node`'s own compensation, or `[]` when it compensates nothing
        def compensates_with_spec_rows(node) = pair_rows(node.to_h[:compensates]&.dig(:with_spec))

        # A read model carries the same options an ask does, plus its filters — see
        # option_rows.
        #
        # @param node [Bluebook::ReadModel] the built read model to read
        # @return [Array<Hash{Symbol => Object}>] see `option_rows`
        def read_model_option_rows(node) = option_rows(node, filters: true)

        # The canonical-form table is the expression grammar's, not this chapter's, so
        # the node is not consulted at all.
        #
        # @param _node [Object] unused — kept for `rows_for`'s uniform shaper signature
        # @return [Array<Hash{Symbol => Object}>] see `normalisation_rows`
        def normalisation_table(_node) = normalisation_rows

        # `lifecycle :status do transition "Retire" => "retired", from: ["issued", "active"] end`
        # is one declaration and two transitions. Offering it once would leave the
        # second unjudged, which is the whole failure this judge exists to avoid.
        #
        # @param node [Bluebook::Aggregate, Bluebook::Entity] the built IR node to read
        # @return [Array<Hash{Symbol => Object}>] `{command:, from_state:, to_state:}`, one
        #   per `from` state `node`'s own lifecycle declares (`[]` with no lifecycle)
        def transition_rows(node)
          lifecycle = node.respond_to?(:lifecycle) ? node.lifecycle : nil
          return [] unless lifecycle

          lifecycle.transitions.flat_map do |command, transition|
            froms = transition.constrained? ? Array(transition.from) : [nil]
            froms.map do |from|
              { command: command, from_state: from, to_state: transition.target }
            end
          end
        end

        # An open map — a member's fields, a dispatch's argument bindings — has no
        # value object that can hold it, so each entry becomes its own row. This is
        # why Member and Dispatch are roots in the language rather than lists.
        #
        # @param map [Hash, nil] an open map read straight off the IR, or nil for none
        # @return [Array<Hash{Symbol => Object}>] `{key:, value:}`, one row per entry
        def pair_rows(map)
          Array(map&.to_h).map { |key, value| { key: key, value: value } }
        end

        # Every specification option an ask carries, flattened to rows.
        #
        # `offset`, `cursor`, `nulls`, `authorize` and `inspect_query` are
        # five options, one compound (authorize names a policy and a
        # tenant). `extra_options_to_h` already spells every one of them
        # and drops the absent ones, so this reads that rather than
        # naming them here — a sixth option needs no change on either
        # side.
        #
        # `filters: true` adds a read model's wheres, order_by and limit —
        # `at` tells repeated rows apart, so two wheres do not collapse.
        #
        # The language may hold more than `to_h` carries, and this is where that
        # mattered. Until 2026-08-11, `ReadModel#to_h` omitted all three —
        # `extra_options_to_h` rejects them by name, still does — so a read
        # model's filtering had never been in the wire contract, and I first
        # read that as a wall: if the wire cannot carry it, the language cannot
        # hold it, and a graph assembled from the language must lose it.
        #
        # That was the wrong conclusion. `to_h` is a projection ; the language
        # is the source. They have to agree about everything
        # to_h spells, not about everything the language knows. Held as option
        # rows, the filters survived the round trip regardless of whether the
        # wire carried them too — which is exactly why, when a later task
        # (Rust read-model codegen) needed `wheres`/`order_by`/`limit` on the
        # wire for an unrelated reason, `ReadModel#to_h` could be extended to
        # spell them (the same mechanism `Query#to_h` already used) without
        # touching this method at all: this reads `node.wheres`/`node.
        # order_by`/`node.limit` off the live object directly below
        # (`filter_options`), never off `to_h`, so the wire format moving did
        # not move this.
        #
        # Named `wheres`, `order_by` and `limit` so they gather back into exactly the
        # declaration keys the assembly already reads.
        #
        # @param node [Bluebook::Query, Bluebook::ReadModel] the built IR node to read
        # @param filters [Boolean] also flatten `node`'s own wheres/order_by/limit
        # @return [Array<Hash{Symbol => Object}>] `{option:, key:, value:, at:}` rows —
        #   `[]` when `node` carries no options
        def option_rows(node, filters: false)
          return [] unless node.respond_to?(:extra_options_to_h)

          spelled = node.extra_options_to_h
          spelled = filter_options(node).merge(spelled) if filters

          spelled.flat_map do |option, held|
            case held
            when Array then held.each_with_index.flat_map { |one, at| parts(option, one, at) }
            else parts(option, held, nil)
            end
          end
        end

        # Rebuilds a read model's own wheres/order_by/limit, absent entries dropped.
        #
        # @param node [Bluebook::ReadModel] the built read model to read
        # @return [Hash{Symbol => Object}] `{wheres:, order_by:, limit:}`, each entry
        #   present only when `node` declares it
        def filter_options(node)
          {
            wheres:   Array(node.wheres).map(&:to_h),
            order_by: node.order_by&.to_h,
            limit:    node.limit&.to_h
          }.reject { |_, held| held.nil? || held == [] }
        end

        # Flattens one option occurrence's own key/value pairs into rows.
        #
        # @param option [Symbol] the option's own name
        # @param held [Object] the option's own value — a scalar, or a Hash-coercible one
        # @param at [Integer, nil] this repetition's own index, or nil when the option
        #   does not repeat
        # @return [Array<Hash{Symbol => Object}>] `{option:, key:, value:, at:}`, one row
        #   per key `held` holds
        def parts(option, held, at)
          Hash(held).map do |key, value|
            { option: option.to_s, key: key.to_s, value: value, at: at&.to_s }
          end
        end

        # A mutation is one declaration, but the language's Change holds a single
        # field/kind/source triple — and an append binds several fields at once
        # (`append: { name: :name, amount: :amount }`). So an append is offered
        # once per binding, and each one is judged.
        #
        # Sending `field: v(""), kind: v("argument"), source: v("")` here instead —
        # three stubbed values — would hand every rule about what a mutation reads
        # a blank, and it could never refuse.
        #
        # @param node [Object] a built IR node carrying `mutations` — a `Command`, an
        #   `Entity`, or similar `Hecks::IR`-including construct
        # @return [Array<Hash{Symbol => Object}>] `{target:, op:, field:, kind:, source:}`,
        #   one row per binding
        def mutation_rows(node)
          Array(node.mutations).flat_map do |mutation|
            # `:delegate`/`:corrects` (CommandBuilder#delegates_to's and
            # #corrects_impl's own comments) ride the same multi-binding
            # shape `:append` does — `with: {...}`/the assembled
            # `as:`/`reason:`/`reverses:` hash is a field map, same as
            # append's own `fields:`.
            next set_row(mutation) unless [:append, :delegate, :corrects].include?(mutation.op)

            mutation.source.map do |field, argument|
              # Spelled the way Mutation#appended_fields spells it, because
              # Assembly::Marks reads this row back through the same reader it
              # reads that field with. `then_set :marks, append: { direction:
              # "out" }` binds a literal, and storing it raw made it
              # indistinguishable from an argument called out.
              { target: mutation.target, op: mutation.op, field: field,
                kind: argument.is_a?(Symbol) ? "argument" : "literal",
                source: Literal.render(argument) }
            end
          end
        end

        # A set/increment/decrement reads one thing: a command argument, or a
        # literal written into the bluebook.
        #
        # @param mutation [Bluebook::Mutation] the built mutation to read
        # @return [Array<Hash{Symbol => Object}>] a single-element Array holding
        #   `{target:, op:, field:, kind:, source:}`
        def set_row(mutation)
          classified = mutation.to_h[:source] || {}

          [{ target: mutation.target, op: mutation.op, field: mutation.target,
             kind: classified[:kind],
             source: classified[:name] || encode_literal(classified[:value]) }]
        end

        # The normalisation table belongs to the expression grammar, not to any one
        # bluebook — it is how the canonical form of a rule is spelled. The language
        # models it because a bluebook's rules are canonicalised on the way in.
        #
        # @return [Array<Hash{Symbol => Object}>] one row per canonicalisation rule the
        #   expression grammar declares, or `[]` if the table cannot be built
        def normalisation_rows
          table = Expression::CanonicalForm.table
          return [] unless table

          table.map do |entry|
            {
              strategy:     entry[:strategy],
              source_token: entry[:source_token],
              replacement:  entry[:replacement],
              boundary:     entry[:boundary],
              position:     entry[:position]
            }
          end
        rescue StandardError
          # The table is a convenience of the Ruby side ; a bluebook that cannot
          # produce one is not malformed.
          []
        end

        # What the bluebook calls a node, whichever kind of thing the node is.
        #
        # Every construct answers `hecks_name` now, so there is nothing to sniff
        # between value objects and anything else (`respond_to?(:hecks_name) ? … :
        # node.name` is not needed). It disappears entirely when the DSL stops
        # handing the judge nodes at all.
        #
        # @param node [Object] a built IR node — an `Aggregate`, `Command`, `Entity`,
        #   `Query`, `ValueObject`, `ReadModel`, `Policy`, `ProcessManager`, `Handler`,
        #   or similar `Hecks::IR`-including construct
        # @return [String] `node`'s own declared name
        def declared_name(node) = node.hecks_name

        # One field of a Declare payload. Mostly a reader of the same name — the
        # exceptions are fields the IR keeps somewhere else, or not at all.
        # Read from the table, not from a branch per category.
        #
        # These were eight hand-written cases — `Entity.owner`, `Member.shape`, two
        # lifecycle members twice over, and three of a query's — each one restating
        # something `Assembly::Contracts` already declares. A parent pointer is
        # `:parent` there ; a folded field names the object and member it lives in.
        # So the exceptions are looked up rather than repeated, and a new fold is one
        # line in one file instead of two lines in two.
        #
        # @param category [String] the node's own category name, such as `"Command"`
        # @param node [Object] the built IR node to read — an `Aggregate`, `Command`,
        #   `Entity`, `Query`, `ValueObject`, `ReadModel`, `Policy`, `ProcessManager`,
        #   `Handler`, or similar `Hecks::IR`-including construct
        # @param field [Symbol] the Declare payload field to read
        # @param parent_id [String, nil] this node's own parent id, returned bare when
        #   `field` is the parent pointer
        # @return [Object, nil] the field's own value — `node.public_send(field)` unless
        #   `field` is folded, the parent pointer, `Query.limit`, or `provenance`; nil when
        #   `node` does not respond to `field`
        def field_value(category, node, field, parent_id)
          return declared_name(node) if field == :name

          contract = Assembly.contract(category)
          # A setter names its target as a string and a Declare field arrives a Symbol,
          # so the lookup keys on a Symbol either way. The case statement this replaced
          # was type-blind because it interpolated ; a Hash is not.
          named    = field.to_sym
          return parent_id if contract.kind_of(named) == :parent

          object, member = contract.folded(named)
          return through(node, object, member) if member

          # `limit` is a language field and an object in the IR — `Array(an_object)`
          # wraps rather than destructures, so offering it stored
          # "#<struct LimitSpec value=3>".
          return node.limit&.to_h&.fetch(:value, nil) if "#{category}.#{field}" == "Query.limit"

          # `provenance from: {...}` is a hash offered into a text field, and
          # handing it over raw let the runtime's own coercion spell it — which
          # meant Ruby's `Hash#to_s`, whose spelling changed under us between
          # 3.3 and 3.4. Encoded here, the same way `default:` already is and the
          # same way Shapes#provenance reads it back.
          return encode_literal(node.provenance) if field == :provenance

          # `identified_by` is no longer a field of any declaration — it is a list,
          # filled by Identify one part at a time, so it is read through `identity_rows`
          # like every other list rather than special-cased here. What this branch
          # existed to protect is now structural : a path cannot come back as its head,
          # because there is nowhere left that holds only a head.

          node.respond_to?(field) ? node.public_send(field) : nil
        end

        # One member of the object a field folds into. `to_h` first, because the
        # member names are the ones the IR spells — a Lifecycle's `default`, an
        # OrderBy's `direction` — and reading the object raw is how a colon or a type
        # goes missing.
        #
        # @param node [Object] the built IR node to read
        # @param object [Symbol, nil] the field naming the object `member` folds into
        # @param member [Symbol] the member to read off that object; `:transitions`
        #   is returned bare rather than read through `to_h`
        # @return [Object, nil] the member's own value, or nil when `node` does not
        #   respond to `object`
        def through(node, object, member)
          held = node.respond_to?(object) ? node.public_send(object) : nil
          return nil unless held

          member == :transitions ? held : held.to_h[member]
        end

        # What a setting command writes. A setter whose source is absent is not
        # dispatched at all — absent is not empty, and offering "" would turn every
        # "if you declare it, declare something" rule into "you must declare it".
        #
        # @param category [String] the node's own category name, such as `"ValueObject"`
        # @param node [Object] the built IR node to read
        # @param target [String] the setter's own target field name
        # @return [Object, nil] the target's own value — `node.public_send(target)` unless
        #   `target` is folded or `"ValueObject.rows"`; nil when `node` does not respond
        #   to `target`
        def setter_value(category, node, target)
          # `rows` folds into `closed_set` and `members` between them, with no single
          # member to name, so it keeps its own reading — see Contract#folded.
          return closed_set_size(node) if "#{category}.#{target}" == "ValueObject.rows"

          object, member = Assembly.contract(category).folded(target.to_sym)
          return through(node, object, member) if member

          node.respond_to?(target) ? node.public_send(target) : nil
        end

        # Only a declared closed set has a row count. An empty one is the defect,
        # so `rows` must stay absent rather than arrive as zero.
        #
        # @param node [Bluebook::ValueObject] the built value object to read
        # @return [Integer, nil] the number of admitted rows, or nil when `node` is
        #   not a declared closed set
        def closed_set_size(node)
          return nil unless node.respond_to?(:closed_set?) && node.closed_set?

          Array(node.members).size
        end

        # `Reference<Customer>` is an IR encoding, not a domain fact. The fact is
        # that the attribute points at Customer's head — so the language is offered
        # that head's ID, and resolution does the rest. Encoding and decoding both
        # live here, because this is where the IR's shape differs from the
        # language's and nowhere else should know the spelling.
        #
        # @param row [Bluebook::Attribute] the built attribute to read
        # @param aggregate_id [String] the chapter id this attribute's own head hangs off
        # @return [String, nil] the pointed-at head's own id, or nil when `row` is not
        #   a reference-typed attribute
        def points_at(row, aggregate_id)
          return nil unless row.reference?

          # The chapter this head is in, and the head it points at — which is exactly
          # how an aggregate is identified, so it is built the same way rather than
          # spelled again with a separator of its own. This is dispatched as a real
          # reference value (`Aggregate.Reference`'s `points_at:`), resolved by
          # `repository.find` against the target Aggregate-within-Meta record's own
          # stored id — so it must equal what that record's identity actually
          # derives, not a wire-format spelling. `reference_type`, below, is the
          # separate later reader that un-derives it back into "Reference<X>".
          Naming.identity([aggregate_id.split(Naming::IDENTITY_JOIN).first, row.type.target_name])
        end

        # A literal, written so it can be read back exactly.
        #
        # The language holds a default and a literal mutation source as text, and
        # `to_s` threw the type away: 0.0 came back "0.0", and `{ value: "good" }`
        # came back its inspect string with nowhere to say it had been a hash. The
        # language already stores code as text — `canonical: "cents >= 0"` — so an
        # encoding is in keeping; it simply has to be self-describing. That rule is
        # now Hecks::Literal's, stated once and shared with every other
        # to_h-bound literal field ; Shapes#decode_literal reads it back.
        #
        # nil stays nil rather than becoming "nil": absent is a real answer here,
        # and the language's own field is optional.
        #
        # @param value [Object, nil] a Ruby value read off the built IR — nil, Symbol,
        #   String, StateRef, true, false, Integer, Float, Hash, or Array
        # @return [String, nil] the self-describing wire spelling `Literal.render` writes,
        #   or nil when `value` is nil
        def encode_literal(value) = value.nil? ? nil : Literal.render(value)

        # The way back out: an aggregate id becomes the type the IR spells. The
        # id is a join of chapter + name (Naming::IDENTITY_JOIN, the same join
        # `points_at` built it with, not the "::" a real bluebook's own type
        # names never carry) ; the wire format wants only the bare name.
        #
        # @param points_at_id [String] a reference-typed attribute's own pointed-at head id
        # @return [String] `"Reference<Name>"`, `points_at_id`'s own bare name
        def reference_type(points_at_id) = "Reference<#{points_at_id.to_s.split(Naming::IDENTITY_JOIN).last}>"

        # One value out of a row, named by the value object's field.
        #
        # @param row [Object] the dispatched row to read — a Hash, a Struct-like object,
        #   or a bare scalar
        # @param field [Symbol] the field to read off `row`
        # @return [Object, nil] `row`'s own value at `field`, or `row` itself for a bare
        #   scalar row
        def row_value(row, field)
          # A Hash first. Hash answers to `key` (Hash#key(value)) and to `value` on
          # some rows, so asking respond_to? before checking for a Hash reads a
          # member pair through entirely the wrong method.
          return row[field] if row.is_a?(Hash)
          return row.public_send(field) if row.respond_to?(field)
          # A Struct answers to [] but raises for a member it does not have, so it
          # is read through to_h — a field the row simply lacks reads as absent.
          return row.to_h[field] if row.respond_to?(:to_h) && !row.is_a?(String)

          # A bare scalar row — `emits` is a list of event names, and the
          # Announcement value object has to call that string something.
          row
        end
      end
    end
  end
end
