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
        # @param category [String] the node's own construct category, such
        #   as `"Command"` or `"ValueObject"`
        # @param list_name [String] the appendable list's own field name
        # @param node [Object] the built IR node being judged
        # @return [Array<Hash>] one row per element of `node`'s own
        #   `list_name`, shaped by the category's own shaper if it has one
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
        # @param node [Object] the built IR node being judged (a `Query` or
        #   `ReadModel`)
        # @return [Array<Hash{Symbol => Object}>] each declared `where`
        #   clause's own fields
        def where_rows(node) = Array(node.wheres).map(&:to_h)

        # The language holds a value object's name here ; the IR holds the object.
        #
        # @param node [Object] the built IR node being judged (an
        #   `Aggregate`)
        # @return [Array<Hash{Symbol => String}>] `{name: ...}` for every
        #   declared value object
        def value_object_names(node) = node.value_objects.map { |shape| { name: shape.hecks_name } }

        # An identity is a list of parts, so it is offered one part at a time — the
        # same way attributes and transitions are. The IR holds the paths ; the
        # language holds a row per path, and the order between them is the whole
        # meaning, because the identity is their join.
        #
        # @param node [Object] the built IR node being judged (an
        #   `Aggregate` or `Entity`)
        # @return [Array<Hash{Symbol => String}>] `{value: ...}` for every
        #   identity path part, in order
        def identity_rows(node) = node.identity_paths.map { |path| { value: path } }

        # Through to_h, which is where Bluebook.render_value spells a symbol argument as
        # ":source". The raw with_spec lost the colon, and a binding that reads an
        # argument became indistinguishable from one carrying a literal string.
        #
        # @param node [Object] the built IR node being judged (a `Dispatch`)
        # @return [Array<Hash{Symbol => Object}>] `pair_rows`' own return
        #   for `node`'s own `with_spec`
        def with_spec_rows(node) = pair_rows(node.to_h[:with_spec])

        # The same read, one level in — `compensates` folds `DispatchSpec`
        # into the language's own `compensates_command_name`/
        # `compensates_with_spec` (`Assembly::Contracts`' own comment on
        # "Dispatch"), so its own with_spec pairs live nested one hash
        # down from where `with_spec_rows` looks. `&.dig(...)` — no
        # compensation at all is not an error, it is `pair_rows(nil)`, empty.
        #
        # @param node [Object] the built IR node being judged (a `Dispatch`)
        # @return [Array<Hash{Symbol => Object}>] `pair_rows`' own return
        #   for `node`'s own `compensates.with_spec`, `[]` when `node` has
        #   no compensation
        def compensates_with_spec_rows(node) = pair_rows(node.to_h[:compensates]&.dig(:with_spec))

        # A read model carries the same options an ask does, plus its filters — see
        # option_rows.
        #
        # @param node [Object] the built IR node being judged (a
        #   `ReadModel`)
        # @return [Array<Hash{Symbol => Object}>] `option_rows`' own return,
        #   with filters included
        def read_model_option_rows(node) = option_rows(node, filters: true)

        # The canonical-form table is the expression grammar's, not this chapter's, so
        # the node is not consulted at all.
        #
        # @param _node [Object] unused; every node shares the one table
        # @return [Array<Hash{Symbol => Object}>] `normalisation_rows`' own
        #   return
        def normalisation_table(_node) = normalisation_rows

        # `lifecycle :status do transition "Retire" => "retired", from: ["issued", "active"] end`
        # is one declaration and two transitions. Offering it once would leave the
        # second unjudged, which is the whole failure this judge exists to avoid.
        #
        # @param node [Object] the built IR node being judged (an
        #   `Aggregate` or `Entity`)
        # @return [Array<Hash{Symbol => Object}>] `:command`, `:from_state`,
        #   and `:to_state`, one row per declared `from` state (or one row
        #   with a `nil` `:from_state` for an unconstrained transition);
        #   `[]` if `node` declares no lifecycle
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
        # @param map [Hash, nil] the open map to flatten, or `nil`
        # @return [Array<Hash{Symbol => Object}>] `{key:, value:}` for every
        #   entry, `[]` when `map` is `nil`
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
        # @param node [Object] the built IR node being judged (a `Query` or
        #   `ReadModel`)
        # @param filters [Boolean] whether to also flatten `node`'s own
        #   `wheres`/`order_by`/`limit`
        # @return [Array<Hash{Symbol => Object}>] `[]` if `node` answers no
        #   `extra_options_to_h`; otherwise `parts`' own rows for every
        #   option `node` carries
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

        # Reads a read model's own filtering fields, in the shape
        # `option_rows` expects to flatten alongside its ordinary options.
        #
        # @param node [Object] the built IR node being judged (a
        #   `ReadModel`)
        # @return [Hash{Symbol => Object}] `:wheres` (`Array<Hash>`),
        #   `:order_by`, and `:limit` (each `Hash` or absent), absent keys
        #   dropped
        def filter_options(node)
          {
            wheres:   Array(node.wheres).map(&:to_h),
            order_by: node.order_by&.to_h,
            limit:    node.limit&.to_h
          }.reject { |_, held| held.nil? || held == [] }
        end

        # Flattens one option's own value (or one element of a repeated
        # option) into key/value rows.
        #
        # @param option [Symbol] the option's own name
        # @param held [Object] the option's own value (a Hash-coercible
        #   object) — one repetition's worth, for a repeated option
        # @param at [Integer, nil] the repetition index, for a repeated
        #   option; `nil` otherwise
        # @return [Array<Hash{Symbol => String, Object}>] `:option`, `:key`,
        #   `:value`, and `:at` (stringified, `nil` when `at` is `nil`), one
        #   per key of `held`
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
        # Sending `field: v(""), kind: v("argument"), source: v("")` here
        # instead — three stubbed values — would hand every rule about what
        # a mutation reads a blank, so it could never refuse.
        #
        # @param node [Object] the built IR node being judged (a `Command`)
        # @return [Array<Hash{Symbol => Object}>] one row per binding for an
        #   append/delegate/corrects mutation, or `set_row`'s own single-row
        #   array for a set/increment/decrement
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
        # @param mutation [Bluebook::Mutation] a set/increment/decrement
        #   mutation
        # @return [Array(Hash{Symbol => Object})] a single-element array
        #   holding `:target`, `:op`, `:field`, `:kind`, and `:source`
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
        # @return [Array<Hash{Symbol => Object}>] one row per admitted
        #   normalisation rule (`:strategy`, `:source_token`, `:replacement`,
        #   `:boundary`, `:position`), `[]` if the table cannot be read
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
        # (`respond_to?(:hecks_name) ? … : node.name`) or choose between. This
        # disappears entirely when the DSL stops handing the judge nodes at all.
        #
        # @param node [Object] the built IR node being judged
        # @return [String] the node's own declared name
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
        # @param category [String] the node's own construct category, such
        #   as `"Command"` or `"ValueObject"`
        # @param node [Object] the built IR node being judged
        # @param field [Symbol] the Declare payload field to read
        # @param parent_id [String] the id the containment walk carries in
        #   from one level up, offered when `field` is the parent pointer
        # @return [Object] `field`'s own value: `node`'s declared name,
        #   `parent_id`, a folded member's value (`through`), the read
        #   model's own limit value, an encoded literal (`provenance`), or
        #   `node.public_send(field)`; `nil` if `node` does not respond to
        #   `field`
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
        # @param node [Object] the built IR node being judged
        # @param object [Symbol] the member object's own field name on
        #   `node`, such as `:lifecycle`
        # @param member [Symbol] the field to read off that object, such as
        #   `:default`; `:transitions` returns the object itself
        # @return [Object, nil] the member's own value, or `nil` if `node`
        #   does not respond to `object` or that object is absent
        def through(node, object, member)
          held = node.respond_to?(object) ? node.public_send(object) : nil
          return nil unless held

          member == :transitions ? held : held.to_h[member]
        end

        # What a setting command writes. A setter whose source is absent is not
        # dispatched at all — absent is not empty, and offering "" would turn every
        # "if you declare it, declare something" rule into "you must declare it".
        #
        # @param category [String] the node's own construct category
        # @param node [Object] the built IR node being judged
        # @param target [Symbol] the setter's own target field
        # @return [Object, nil] the target's own value: the closed set's own
        #   row count, a folded member's value (`through`), or
        #   `node.public_send(target)`; `nil` if absent
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
        # @param node [Object] the built IR node being judged (a
        #   `ValueObject`)
        # @return [Integer, nil] the closed set's own row count, or `nil` if
        #   `node` is not a declared closed set
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
        # @param row [Bluebook::Attribute] the attribute being offered
        # @param aggregate_id [String] the owning head's own id, read for
        #   its chapter prefix
        # @return [String, nil] the target head's own id, or `nil` if `row`
        #   is not a `reference_to` attribute
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
        # @param value [Object] the value to encode: `nil`, `Symbol`,
        #   `String`, `Hecks::StateRef`, `true`, `false`, `Integer`, `Float`,
        #   `Hash`, or `Array` (recursively)
        # @return [String, nil] the self-describing wire spelling, or `nil`
        #   when `value` is `nil`
        def encode_literal(value) = value.nil? ? nil : Literal.render(value)

        # The way back out: an aggregate id becomes the type the IR spells. The
        # id is a join of chapter + name (Naming::IDENTITY_JOIN, the same join
        # `points_at` built it with, not the "::" a real bluebook's own type
        # names never carry) ; the wire format wants only the bare name.
        #
        # @param points_at_id [String] a target head's own id, as `points_at`
        #   built it
        # @return [String] `"Reference<Name>"`, the bare target name
        def reference_type(points_at_id) = "Reference<#{points_at_id.to_s.split(Naming::IDENTITY_JOIN).last}>"

        # One value out of a row, named by the value object's field.
        #
        # @param row [Hash, Object] the row to read: a Hash, an object
        #   answering `field` directly, an object answering `to_h`, or a
        #   bare scalar
        # @param field [Symbol] the field name to read
        # @return [Object] `row[field]` for a Hash, `row.public_send(field)`
        #   when `row` answers `field` directly, `row.to_h[field]` for
        #   anything else to_h-able, or `row` itself for a bare scalar
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
