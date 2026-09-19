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
        # @param field [Hash{Symbol => Object}] one declared field's row, with `:type`,
        #   `:name`, `:list`, `:default`, `:optional`, `:pattern`, `:admits` and
        #   `:relationship` keys
        # @return [Bluebook::Attribute] the rebuilt attribute, its `type` a
        #   `Bluebook::Reference` when `field[:type]` spells `"Reference<...>"`, else
        #   the type name
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
        # @param field [Hash{Symbol => Object}] one declared field's row, same shape
        #   as `attribute`'s own
        # @return [Bluebook::Attribute] the rebuilt attribute
        def shape_field(field) = attribute(field)

        # One part of an identity. It goes in as a row so the language can hold an
        # ordered list of them, and comes back out as the path it always was —
        # a String, because `identity_paths` splits paths and never symbols.
        #
        # @param part [Hash{Symbol => Object}] one identity path row, with a `:value` key
        # @return [String] the identity path
        def identity_path(part) = part[:value].to_s

        # A member's fields — an open map, which is why Member is its own root in
        # the language and why the pairs arrive as a list rather than a value object.
        #
        # The values are unmarked, because `ValueObject#to_h` spells them with `to_s`
        # and the language stores them as text: `member code: "JPY", minor_units: 0`
        # came back with a minor_units of "0", and a closed set that admits the string
        # would refuse the number the caller passes.
        #
        # @param pairs [Array<Array(String, Object)>, Hash] the member's declared
        #   `key => value` pairs
        # @return [Hash{Symbol => Object}] the pairs, keyed by symbol, each value read
        #   through `unmark_scalar`
        def member(pairs)
          pairs.to_h { |key, value| [key.to_sym, unmark_scalar(value)] }
        end

        # A read model's gathered head. The keys must be symbols whichever way the
        # declaration arrived, and `as` must be one too: it names the reader the
        # projection answers to, and `ReadModel#to_h` spells it `to_s`.
        #
        # @param row [Hash{Symbol, String => Object}] one included aggregate's row, with
        #   `:aggregate`, `:as` and `:many` keys (or their String-keyed equivalents)
        # @return [Hash{Symbol => Object}] the row, keyed by symbol, with `:as` coerced
        #   to a Symbol
        def head(row)
          row.to_h { |key, value| [key.to_sym, key.to_sym == :as ? value.to_sym : value] }
        end

        # A group_by field's own name — the builder's native shape is already
        # `{field: :symbol}`, so this matches it rather than leaving `field`
        # as the String `Shapes#group_by_field` reads back.
        #
        # @param row [Hash{Symbol => Object}] one group-by row, with a `:field` key
        # @return [Hash{field: Symbol}] the field name, coerced to a Symbol
        def group_by_field(row) = { field: row[:field].to_sym }

        # A scalar that was written as itself rather than inspected — a member's
        # value, where the language holds text and the type has to be read back from
        # the shape of it. Unlike `read`, a bare word stays a String here, because
        # a closed set admits words far more often than symbols.
        #
        # @param value [Object] the raw declared scalar
        # @return [String, Integer, Float, Boolean] `true`/`false` for those exact
        #   words, an Integer or Float when the text is entirely digits, else the
        #   text itself
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
        # @param with [Hash, Array<Array(String, String)>, nil] the declared
        #   `key => value` bindings; `nil` reads as no bindings
        # @return [Hash{Symbol => Object}] the bindings, keyed by symbol, each value
        #   read through `read`
        def bindings(with) = Array(with).to_h { |key, value| [key.to_sym, read(value)] }

        # Rebuilds a declared invariant from its rule row.
        #
        # @param rule [Hash{Symbol => String, nil}] one declared rule row, with
        #   `:description` and `:canonical` keys
        # @return [Bluebook::Invariant] the rebuilt invariant
        def invariant(rule)
          Invariant.new(description: rule[:description], canonical: rule[:canonical])
        end

        # Rebuilds a declared given from its rule row.
        #
        # @param rule [Hash{Symbol => String, nil}] one declared rule row, with
        #   `:description` and `:canonical` keys
        # @return [Bluebook::Given] the rebuilt given
        def given(rule)
          Given.new(description: rule[:description], canonical: rule[:canonical])
        end

        # S12, ADR 0025 — `projects :name, from: :"reference.remote_field"`.
        # All three fields are identifiers, unlike Invariant/Given's own
        # free text, so — like `attribute`'s own `name`/`type` below —
        # they come back as Symbols.
        #
        # @param row [Hash{Symbol => String}] one declared `projects` row, with
        #   `:name`, `:reference` and `:remote_field` keys
        # @return [Bluebook::ProjectedField] the rebuilt projected field
        def projected_field(row)
          ProjectedField.new(name: row[:name].to_sym, reference: row[:reference].to_sym,
                             remote_field: row[:remote_field].to_sym)
        end

        # `Mutation#to_h` branches on the operation, so this does too.
        #
        # An append binds several fields at once, each either an argument (a
        # Symbol, wearing its colon) or a literal — the distinction that keeps
        # `append: { direction: "out" }` from reading as indistinguishable from
        # an argument named `out`.
        #
        # @param change [Hash{Symbol => Object}] one declared mutation row, with `:target`,
        #   `:op` and either `:fields` (for `append`/`delegate`/`corrects`) or `:source`
        # @return [Bluebook::Mutation] the rebuilt mutation
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

        # Reads back an append's several field bindings.
        #
        # @param fields [Hash, Array<Array(String, String)>, nil] the declared
        #   `field => source` bindings
        # @return [Hash{Symbol => Object}] the bindings, keyed by symbol, each source
        #   read through `read`
        def appended(fields)
          Array(fields).to_h { |field, source| [field.to_sym, read(source)] }
        end

        # A set reads one thing, and `classified_source` said which: an argument by
        # name, or a literal by value.
        #
        # @param source [Hash{Symbol => Object}, nil] the declared, classified source row,
        #   with a `:kind` key (`"argument"`, `"state"` or `"literal"`) and its matching
        #   `:name`/`:value`
        # @return [Symbol, StateRef, Object, nil] the argument name as a Symbol, a
        #   `StateRef` for a `state(:name)` read, the literal value as-is, or `nil` when
        #   `source` is `nil`
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
        # come back through here. There were two readers (`read` and `unmark`)
        # that disagreed about quoted strings and numbers, and which one a call
        # site got was a coin toss the comments had to keep apologising for.
        #
        # An object literal is the one that bit. A saga leg binds `narrative: {
        # text: "transfer out" }` — a value object's fields written inline — and
        # plain `to_s` on a Hash renders its inspect form, so it comes back as
        # text. Read as a string it reached the runtime as `"{:text=>\"transfer out\"}"`,
        # coercion refused it, the debit leg was never delivered, and the whole
        # settlement wire stopped: banking emitted TransferRequested five times and
        # TransferDebited never. A whole-history replay gate caught what every other
        # gate missed, because a saga that silently does nothing looks exactly like
        # a saga with nothing to do.
        #
        # @param value [String, #to_s] the wire spelling `Literal.render` produced
        # @return [Object] `nil`, `true`, `false`, Integer, Float, Symbol, `StateRef`,
        #   String, Hash or Array — whichever spelling `value` matches
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
        # @param clause [Hash{Symbol => Object}] one declared `where` row, with `:field`,
        #   `:op`, `:value` and an optional `:target`
        # @return [QuerySpecification::Common::WhereClause] the rebuilt where clause
        def where_clause(clause)
          QuerySpecification::Common::WhereClause.new(
            field: clause[:field], op: clause[:op].to_sym, value: read(clause[:value]), target: clause[:target]
          )
        end

        # Rebuilds a declared `order_by` row into its struct.
        #
        # @param declared [Hash{Symbol => Object}, nil] the declared `order_by` row, with
        #   `:field`, `:direction` and an optional `:target`; `nil` for no `order_by`
        # @return [QuerySpecification::Common::OrderBy, nil] the rebuilt ordering, or
        #   `nil` if none is declared
        def order_by(declared)
          return nil unless declared

          QuerySpecification::Common::OrderBy.new(
            field: declared[:field], direction: declared[:direction].to_sym, target: declared[:target]
          )
        end

        # Rebuilds a declared `limit` row into its struct.
        #
        # @param declared [Hash{Symbol => Object}, nil] the declared `limit` row, with
        #   `:value` and an optional `:target`; `nil` for no `limit`
        # @return [QuerySpecification::Common::LimitSpec, nil] the rebuilt limit, or `nil`
        #   if none is declared
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

        # Rebuilds one open-map specification option into its own struct.
        #
        # @param name [Symbol] the option's name, a key of `OPTIONS` (`:offset`, `:cursor`,
        #   `:null_semantics`, `:authorization` or `:inspection`)
        # @param declared [Hash{Symbol => Object}, nil] the option's declared members;
        #   `nil` for an undeclared option
        # @return [Object, nil] an instance of `OPTIONS[name]`'s struct, or `nil` if
        #   `declared` is `nil`
        def option(name, declared)
          return nil if declared.nil?

          holder, marked = OPTIONS.fetch(name)
          holder.new(**Hash(declared).to_h { |key, value| [key, option_value(key, value, marked)] })
        end

        # Reads back one option member, choosing the decoding `OPTIONS`/`SYMBOLIC` name.
        #
        # @param key [Symbol] the member's name
        # @param value [Object, nil] the member's declared value
        # @param marked [Array<Symbol>] the members of this option that ride Literal's
        #   spelling, from `OPTIONS[name]`'s second element
        # @return [Object, nil] `nil` for a `nil` value, the value read through `read` when
        #   `key` is in `marked`, the value as a Symbol when `key` is in `SYMBOLIC`, else
        #   the value as-is
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
