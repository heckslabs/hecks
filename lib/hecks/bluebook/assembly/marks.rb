module Hecks
  module Bluebook
    class Assembly
      # The leaf shapes an assembly reads, and the encodings it undoes.
      #
      # `to_h` spells things as text so the export stands on its own, and every
      # one of those spellings has to come back apart here. This is the same family
      # of work `MetaValidator::Shapes` does for the reconstruction — the difference
      # is that Shapes rebuilds hashes and this rebuilds objects, so it has to
      # recover types rather than just strings.
      #
      # Encoding losses are the largest family of bug in this codebase, and every
      # member has the same shape: reading an object where `to_h` holds a spelling.
      # So each method below names the spelling it inverts.
      module Marks
        module_function

        # `Attribute#to_h` spells a type with `to_s`, so a reference arrives as
        # "Reference<Customer>" and has to become an edge again. Everything else is
        # a name and stays one.
        #
        # @param field [Hash{Symbol => Object}] one attribute's declared row, keyed
        #   `:type` (String, a plain type name or `"Reference<Target>"`), `:name`
        #   (String), `:list` and `:optional` (read as truthy), `:default` (Object,
        #   nil), `:pattern` (String, nil), `:admits` (String, nil) and
        #   `:relationship` (String, nil), each the raw declared value
        # @return [Bluebook::Attribute] the attribute, with `type` resolved to a
        #   `Bluebook::Reference` when the row spelled one
        def attribute(field)
          type = field[:type].to_s
          target = type[/\AReference<(.+)>\z/, 1]

          Attribute.new(
            name:         field[:name],
            type:         target ? Reference.new(target) : type,
            list:         field[:list] ? true : false,
            default:      field[:default],
            # The last place optionality can be dropped, and the one that was
            # dropping it. Every bluebook in the registry is the round-trip
            # product — MetaValidator dispatches the declaration in and reads it
            # back — so a fact this constructor does not carry is a fact the
            # language cannot state about itself, however plainly the source
            # wrote it.
            optional:     field[:optional] ? true : false,
            pattern:      field[:pattern],
            # **The same lesson, one fact later**. `admits` is not on `to_h` — the
            # wire does not carry it, on purpose — but it must still survive the
            # round trip, because the grammar registry keeps the assembled graph
            # and downstream projections read the link off that. Dropped here, the
            # language could not say `admits` about itself no matter how plainly
            # the source wrote it, which is word for word what the note above
            # already learned about `optional`.
            admits:       field[:admits],
            relationship: field[:relationship]
          )
        end

        # The same shape. Two names because a head's field and a verb's argument are
        # different things in the language even though the IR keeps one class for
        # both — `Aggregate.Attribute` and `Command.Argument` are separate verbs.
        #
        # @param field [Hash{Symbol => Object}] see `attribute`
        # @return [Bluebook::Attribute] see `attribute`
        def shape_field(field) = attribute(field)

        # One part of an identity. It goes in as a row so the language can hold an
        # ordered list of them, and comes back out as the path it always was —
        # a String, because `identity_paths` splits paths and never symbols.
        #
        # @param part [Hash{Symbol => Object}] one identity-path row, keyed `:value`
        #   (Object, read via `to_s`)
        # @return [String] the path segment
        def identity_path(part) = part[:value].to_s

        # A member's fields — an open map, which is why Member is its own root in
        # the language and why the pairs arrive as a list rather than a value object.
        #
        # The values are unmarked, because `ValueObject#to_h` spells them with `to_s`
        # and the language stores them as text: `member code: "JPY", minor_units: 0`
        # came back with a minor_units of "0", and a closed set that admits the string
        # would refuse the number the caller passes.
        #
        # @param pairs [Array<Array(String, Object)>] one member's own field pairs,
        #   each `[field_name, raw_value]` as declared
        # @return [Hash{Symbol => Object}] the member's fields, keyed by field name,
        #   each value read back to its native type through `unmark_scalar`
        def member(pairs)
          pairs.to_h { |key, value| [key.to_sym, unmark_scalar(value)] }
        end

        # A read model's gathered head. The keys must be symbols whichever way the
        # declaration arrived, and `as` must be one too: it names the reader the
        # projection answers to, and `ReadModel#to_h` spells it `to_s`.
        #
        # @param row [Hash{Symbol => Object}] one aggregate-head row, keyed
        #   `:aggregate` (String), `:as` (String, the reader name) and `:many`
        #   (Boolean)
        # @return [Hash{Symbol => Object}] the head, with every key a Symbol and
        #   `:as` read back to a Symbol
        def head(row)
          row.to_h { |key, value| [key.to_sym, key.to_sym == :as ? value.to_sym : value] }
        end

        # A group_by field's own name — the builder's native shape is already
        # `{field: :symbol}`, so this matches it rather than leaving `field`
        # as the String `Shapes#group_by_field` reads back.
        #
        # @param row [Hash{Symbol => String}] one group-by row, keyed `:field`
        # @return [Hash{field: Symbol}] the row with `:field` read back to a Symbol
        def group_by_field(row) = { field: row[:field].to_sym }

        # A scalar that was written as itself rather than inspected — a member's
        # value, where the language holds text and the type has to be read back from
        # the shape of it. Unlike `read`, a bare word stays a String here, because
        # a closed set admits words far more often than symbols.
        #
        # @param value [Object] the raw declared scalar, read via `to_s`
        # @return [true, false, Integer, Float, String] `true`/`false` for those
        #   literal words, a number when the text matches a bare integer or decimal
        #   pattern, or the string itself otherwise
        def unmark_scalar(value)
          text = value.to_s
          return true       if text == "true"
          return false      if text == "false"
          return text.to_i  if text.match?(/\A-?\d+\z/)
          return text.to_f  if text.match?(/\A-?\d+\.\d+\z/)

          text
        end

        # A saga's argument bindings. Each value rides Literal's spelling, which
        # marks a Symbol with a leading colon — lose it and an argument reads as a
        # string of the same name.
        #
        # @param with [Array<Array(String, String)>, nil] the declared bindings,
        #   each `[argument_name, literal_spelling]` pair, or `nil` for none
        # @return [Hash{Symbol => Object}] the bindings, keyed by argument name,
        #   each value read back through `Literal.read`
        def bindings(with) = Array(with).to_h { |key, value| [key.to_sym, read(value)] }

        # Builds one aggregate or value object invariant from its declared row.
        #
        # @param rule [Hash{Symbol => String}] one invariant's declared row, keyed
        #   `:description` and `:canonical` (the canonical-form rendering of the
        #   rule's expression)
        # @return [Bluebook::Invariant] the invariant, with `predicate`/`ast` left
        #   `nil` — `Expression::Evaluator` parses `canonical` on demand when
        #   neither is set
        def invariant(rule)
          Invariant.new(description: rule[:description], canonical: rule[:canonical])
        end

        # Builds one command precondition from its declared row.
        #
        # @param rule [Hash{Symbol => String}] one given's declared row, keyed
        #   `:description` and `:canonical` (the canonical-form rendering of the
        #   rule's expression)
        # @return [Bluebook::Given] the given, with `predicate`/`ast` left `nil` —
        #   `Expression::Evaluator` parses `canonical` on demand when neither is set
        def given(rule)
          Given.new(description: rule[:description], canonical: rule[:canonical])
        end

        # S12, ADR 0025 — `projects :name, from: :"reference.remote_field"`.
        # All three fields are identifiers, unlike Invariant/Given's own
        # free text, so — like `attribute`'s own `name`/`type` below —
        # they come back as Symbols.
        #
        # @param row [Hash{Symbol => String}] one projected-field's declared row,
        #   keyed `:name`, `:reference` and `:remote_field` (each an identifier)
        # @return [Bluebook::ProjectedField] the projected field, with each
        #   identifier read back to a Symbol
        def projected_field(row)
          ProjectedField.new(name: row[:name].to_sym, reference: row[:reference].to_sym,
                             remote_field: row[:remote_field].to_sym)
        end

        # `Mutation#to_h` branches on the operation, so this does too.
        #
        # An append binds several fields at once, each either an argument (a
        # Symbol, wearing its colon) or a literal — the distinction that is the
        # whole reason `append: { direction: "out" }` was once indistinguishable
        # from an argument named `out`.
        #
        # @param change [Hash{Symbol => Object}] one mutation's declared row, keyed
        #   `:target` (String), `:op` (String, such as `"set"`, `"append"`,
        #   `"delegate"` or `"corrects"`), `:fields` (Array, for the append-shaped
        #   ops) and `:source` (Hash, for any other op)
        # @return [Bluebook::Mutation] the mutation, with `source` a
        #   `Hash{Symbol => Object}` of field bindings for an append-shaped op, or
        #   `classified`'s own result for any other
        def mutation(change)
          target = change[:target].to_sym
          op     = change[:op].to_sym

          # `:delegate`/`:corrects` (CommandBuilder#delegates_to's and
          # #corrects_impl's own comments) ride the same multi-binding
          # shape `:append` does.
          return Mutation.new(target: target, op: op, source: appended(change[:fields])) if [:append, :delegate,
                                                                                             :corrects].include?(op)

          Mutation.new(target: target, op: op, source: classified(change[:source]))
        end

        # Reads an append mutation's field bindings back off their declared rows.
        #
        # @param fields [Array<Array(String, String)>, nil] the append's declared
        #   field bindings, each `[field_name, literal_spelling]` pair, or `nil`
        #   for none
        # @return [Hash{Symbol => Object}] the bindings, keyed by field name, each
        #   value read back through `Literal.read`
        def appended(fields)
          Array(fields).to_h { |field, source| [field.to_sym, read(source)] }
        end

        # A set reads one thing, and `classified_source` said which: an argument by
        # name, or a literal by value.
        #
        # @param source [Hash{Symbol => Object}, nil] the mutation's declared
        #   source, keyed `:kind` (String, `"argument"`, `"state"` or a literal
        #   kind) plus `:name` (String, for `"argument"`/`"state"`) or `:value`
        #   (Object, for a literal), or `nil` for no source
        # @return [Symbol, Hecks::StateRef, Object, nil] the command argument name,
        #   a state self-reference, the literal value, or `nil` when `source` is
        #   `nil`
        def classified(source)
          return nil if source.nil?

          case source[:kind].to_s
          when "argument" then source[:name].to_sym
          when "state"    then StateRef.new(source[:name].to_sym)
          else source[:value]
          end
        end

        # Every literal field on the wire, read back — one spelling, one reader.
        #
        # A where-clause value, a saga's argument bindings, an append binding, a
        # limit: all of them ride Literal's self-describing form, so all of them
        # come back through this one reader, never a second one that might
        # disagree about a quoted string or a number.
        #
        # An object literal is the one that bites hardest. A saga leg binds
        # `narrative: { text: "transfer out" }` — a value object's fields written
        # inline — and reading it as a plain string rather than through `Literal`
        # would reach the runtime as `"{:text=>\"transfer out\"}"`, which coercion
        # refuses: the debit leg is never delivered, and the whole settlement wire
        # stops — banking emits TransferRequested five times and TransferDebited
        # never. A whole-history replay gate is what catches this, because a saga
        # that silently does nothing looks exactly like a saga with nothing to do.
        #
        # @param value [String, Object] wire spelling produced by `Literal.render`,
        #   or a bare word
        # @return [nil, true, false, Integer, Float, Symbol, Hecks::StateRef,
        #   String, Hash, Array] the value read back — see `Literal.read`
        def read(value) = Literal.read(value)

        # `target:` (ADR 0055) — read straight off the wire, unconverted:
        # it's already the bare aggregate-name string `WhereClause#to_h`/
        # `OrderBy#to_h`/`LimitSpec#to_h` wrote (`resolve_target`'s own
        # `Naming.demodulise` already ran once, at DSL-build time; this is
        # the replay path every real boot actually goes through, reading
        # that same wire shape back — see this class's own header). Absent
        # from `clause`/`declared` entirely on older wire data that never
        # declared `on:` — `clause[:target]`/`declared[:target]` reads
        # `nil` for a missing key exactly like an explicit `nil` would,
        # so this is additive, not a migration.
        #
        # @param clause [Hash{Symbol => Object}] one where-clause's declared row,
        #   keyed `:field` (String), `:op` (String, a comparator name), `:value`
        #   (String, Literal's spelling) and `:target` (String, `nil` when absent)
        # @return [QuerySpecification::Common::WhereClause] the clause, with `op`
        #   read to a Symbol and `value` read back through `Literal.read`
        def where_clause(clause)
          QuerySpecification::Common::WhereClause.new(
            field: clause[:field], op: clause[:op].to_sym, value: read(clause[:value]), target: clause[:target]
          )
        end

        # Builds a query's declared ordering, if it declares one.
        #
        # @param declared [Hash{Symbol => Object}, nil] the declared order-by row,
        #   keyed `:field` (String), `:direction` (String) and `:target` (String,
        #   `nil` when absent), or `nil` when the construct declares no ordering
        # @return [QuerySpecification::Common::OrderBy, nil] the order-by, with
        #   `direction` read to a Symbol, or `nil` when `declared` is `nil`
        def order_by(declared)
          return nil unless declared

          QuerySpecification::Common::OrderBy.new(
            field: declared[:field], direction: declared[:direction].to_sym, target: declared[:target]
          )
        end

        # Builds a query's declared limit, if it declares one.
        #
        # @param declared [Hash{Symbol => Object}, nil] the declared limit row,
        #   keyed `:value` (String, Literal's spelling) and `:target` (String,
        #   `nil` when absent), or `nil` when the construct declares no limit
        # @return [QuerySpecification::Common::LimitSpec, nil] the limit, with
        #   `value` read back through `Literal.read`, or `nil` when `declared` is
        #   `nil`
        def limit(declared)
          return nil unless declared

          QuerySpecification::Common::LimitSpec.new(value: read(declared[:value]), target: declared[:target])
        end

        # Every other specification option, from one table.
        #
        # Each entry names the struct and which of its members carry a value that
        # rode Literal's spelling rather than plain text. A
        # ninth option is one row here and nothing else — the language already holds
        # it, because it holds options as an open map rather than a field each.
        OPTIONS = {
          offset:         [QuerySpecification::Common::OffsetSpec,        %i[value]],
          cursor:         [QuerySpecification::Common::CursorSpec,        %i[value]],
          null_semantics: [QuerySpecification::Common::NullSemantics,     []],
          authorization:  [QuerySpecification::Common::AuthorizationSpec, %i[policy tenant]],
          inspection:     [QuerySpecification::Common::InspectionSpec,    []]
        }.freeze

        # `mode` and `policy` are read as symbols because the DSL declares them that
        # way — `nulls :last`, `authorize :customer_access` — and `to_h` spells them
        # with `to_s`, so the colon is not there to strip.
        SYMBOLIC = %i[mode policy tenant].freeze

        # Builds one query specification option from its declared row and `OPTIONS`.
        #
        # @param name [Symbol] the option's name, a key of `OPTIONS` (`:offset`,
        #   `:cursor`, `:null_semantics`, `:authorization` or `:inspection`)
        # @param declared [Hash{Symbol => Object}, nil] the option's declared row,
        #   or `nil` when the construct does not declare this option
        # @return [QuerySpecification::Common::OffsetSpec,
        #   QuerySpecification::Common::CursorSpec,
        #   QuerySpecification::Common::NullSemantics,
        #   QuerySpecification::Common::AuthorizationSpec,
        #   QuerySpecification::Common::InspectionSpec, nil] the option built
        #   through the holder `OPTIONS` names for `name`, or `nil` when `declared`
        #   is `nil`
        # @raise [KeyError] if `name` is not a key of `OPTIONS`
        def option(name, declared)
          return nil if declared.nil?

          holder, marked = OPTIONS.fetch(name)
          holder.new(**Hash(declared).to_h { |key, value| [key, option_value(key, value, marked)] })
        end

        # Reads one option member's declared value back to its native type.
        #
        # @param key [Symbol] the option member's name being read
        # @param value [Object, nil] the declared value for that member
        # @param marked [Array<Symbol>] the members of this option that ride
        #   Literal's spelling, from `OPTIONS`
        # @return [Object, nil] `value` read back through `Literal.read` when
        #   `key` is marked, a Symbol when `key` is one of `SYMBOLIC`, the raw
        #   `value` otherwise, or `nil` when `value` is `nil`
        def option_value(key, value, marked)
          return nil               if value.nil?
          return read(value)       if marked.include?(key)
          return value.to_sym      if SYMBOLIC.include?(key)

          value
        end
      end
    end
  end
end
