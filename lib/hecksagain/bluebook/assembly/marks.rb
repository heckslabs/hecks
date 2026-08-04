module Hecksagain
  module Bluebook
    class Assembly
      # The leaf shapes an assembly reads, and the encodings it undoes.
      #
      # `to_h` spells things as text so the export stands on its own, and every
      # one of those spellings has to come back apart here. This is the same family
      # of work `MetaValidator::Shapes` does for the reconstruction — the difference
      # is that Shapes rebuilds HASHES and this rebuilds OBJECTS, so it has to
      # recover types rather than just strings.
      #
      # ENCODING LOSSES ARE THE LARGEST FAMILY OF BUG IN THIS CODEBASE, and every
      # member has the same shape: reading an object where `to_h` holds a spelling.
      # So each method below names the spelling it inverts.
      module Marks
        module_function

        # `IR::Attribute#to_h` spells a type with `to_s`, so a reference arrives as
        # "Reference<Customer>" and has to become an edge again. Everything else is
        # a name and stays one.
        def attribute(field)
          type = field[:type].to_s
          target = type[/\AReference<(.+)>\z/, 1]

          IR::Attribute.new(
            name:     field[:name],
            type:     target ? IR::Reference.new(target) : type,
            list:     field[:list] ? true : false,
            default:  field[:default],
            # The LAST place optionality can be dropped, and the one that was
            # dropping it. Every bluebook in the registry is the round-trip
            # product — MetaValidator dispatches the declaration in and reads it
            # back — so a fact this constructor does not carry is a fact the
            # language cannot state about itself, however plainly the source
            # wrote it.
            optional: field[:optional] ? true : false,
            pattern:  field[:pattern],
            # THE SAME LESSON, ONE FACT LATER. `admits` is not on `to_h` — the
            # wire does not carry it, on purpose — but it must still survive the
            # round trip, because the grammar registry keeps the ASSEMBLED graph
            # and downstream projections read the link off that. Dropped here, the
            # language could not say `admits` about itself no matter how plainly
            # the source wrote it, which is word for word what the note above
            # already learned about `optional`.
            admits:   field[:admits]
          )
        end

        # The same shape. Two names because a head's field and a verb's argument are
        # different things in the language even though the IR keeps one class for
        # both — `Aggregate.Attribute` and `Command.Argument` are separate verbs.
        def shape_field(field) = attribute(field)

        # ONE PART OF AN IDENTITY. It goes in as a row so the language can hold an
        # ordered list of them, and comes back out as the path it always was —
        # a String, because `identity_paths` splits paths and never symbols.
        def identity_path(part) = part[:value].to_s

        # A member's fields — an OPEN MAP, which is why Member is its own root in
        # the language and why the pairs arrive as a list rather than a value object.
        #
        # The values are UNMARKED, because `ValueObject#to_h` spells them with `to_s`
        # and the language stores them as text: `member code: "JPY", minor_units: 0`
        # came back with a minor_units of "0", and a closed set that admits the string
        # would refuse the number the caller passes.
        def member(pairs)
          pairs.to_h { |key, value| [key.to_sym, unmark_scalar(value)] }
        end

        # A read model's gathered head. The keys must be symbols whichever way the
        # declaration arrived, and `as` must be one too: it NAMES the reader the
        # projection answers to, and `ReadModel#to_h` spells it `to_s`.
        def head(row)
          row.to_h { |key, value| [key.to_sym, key.to_sym == :as ? value.to_sym : value] }
        end

        # A scalar that was written as itself rather than inspected — a member's
        # value, where the language holds text and the type has to be read back from
        # the shape of it. Unlike `unmark`, a bare word stays a String here, because
        # a closed set admits words far more often than symbols.
        def unmark_scalar(value)
          text = value.to_s
          return true       if text == "true"
          return false      if text == "false"
          return text.to_i  if text.match?(/\A-?\d+\z/)
          return text.to_f  if text.match?(/\A-?\d+\.\d+\z/)

          text
        end

        # A saga's argument bindings. Each value rides `render_value`, which marks a
        # Symbol with a leading colon — lose it and an argument reads as a string of
        # the same name. `unmark`, not `read`, for the same reason `where_clause`
        # needed it over `read` : nothing in the real corpus has ever bound a
        # literal number or boolean (every `with:` is a kwarg reference or an
        # object literal), so `read`'s missing numeric/boolean cases were a latent
        # gap, not yet a proven one — a saga leg dispatching `with: { retry: 3 }`
        # would bind the STRING "3", silently, to whatever the target command's
        # argument coercion did with it.
        def bindings(with) = Array(with).to_h { |key, value| [key.to_sym, unmark(value)] }

        def invariant(rule)
          IR::Invariant.new(description: rule[:description], canonical: rule[:canonical])
        end

        def given(rule)
          IR::Given.new(description: rule[:description], canonical: rule[:canonical])
        end

        # `Mutation#to_h` branches on the operation, so this does too.
        #
        # An APPEND binds several fields at once and spells each binding with
        # `value.is_a?(Symbol) ? value.to_s : value.inspect` — so a bare word is an
        # ARGUMENT and anything self-describing is a LITERAL. That distinction is
        # the whole reason `append: { direction: "out" }` was once indistinguishable
        # from an argument named `out`.
        def mutation(change)
          target = change[:target].to_sym
          op     = change[:op].to_sym

          return IR::Mutation.new(target: target, op: op, source: appended(change[:fields])) if op == :append

          IR::Mutation.new(target: target, op: op, source: classified(change[:source]))
        end

        def appended(fields)
          Array(fields).to_h { |field, source| [field.to_sym, source_of(source)] }
        end

        # A SET reads one thing, and `classified_source` said which: an argument by
        # name, or a literal by value.
        def classified(source)
          return nil if source.nil?

          source[:kind].to_s == "argument" ? source[:name].to_sym : source[:value]
        end

        # Bare word -> the argument it names. Anything wearing its own type -> the
        # literal it is. `inspect` is what wrote these, so `unmark` reads them.
        def source_of(spelling)
          text = spelling.to_s
          return text.to_sym if text.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

          unmark(text)
        end

        # `QuerySpecification.render_value` spells a Symbol ":name" and everything
        # else `to_s`. A where-clause value and a saga's argument bindings both ride
        # that spelling, and losing the colon made an argument indistinguishable
        # from a string of the same name.
        #
        # AN OBJECT LITERAL RIDES IT TOO, and that is the one that bit. A saga leg
        # binds `narrative: { text: "transfer out" }` — a value object's fields
        # written inline — and `to_s` on a Hash is its inspect form, so it comes back
        # as text. Read as a string it reached the runtime as
        # `"{:text=>\"transfer out\"}"`, coercion refused it, the debit leg was never
        # delivered, and the whole settlement wire stopped: banking emitted
        # TransferRequested five times and TransferDebited never. A whole-history
        # replay gate caught what
        # every other gate missed, because a saga that silently does nothing looks
        # exactly like a saga with nothing to do.
        def read(value)
          text = value.to_s
          return object(text)     if text.start_with?("{") && text.end_with?("}")
          return text[1..].to_sym if text.start_with?(":")

          text
        end

        # A literal, from the self-describing form `inspect` produced.
        def unmark(text)
          raw = text.to_s
          return nil                if raw.empty?
          return object(raw)        if raw.start_with?("{") && raw.end_with?("}")
          return raw[1..-2]         if raw.start_with?('"') && raw.end_with?('"')
          return raw[1..].to_sym    if raw.start_with?(":")
          return true               if raw == "true"
          return false              if raw == "false"
          return raw.to_i           if raw.match?(/\A-?\d+\z/)
          return raw.to_f           if raw.match?(/\A-?\d+\.\d+\z/)

          raw
        end

        # Scanned rather than split on ", ", so a quoted value carrying a comma does
        # not tear in half.
        def object(raw)
          raw.scan(/:(\w+)=>("[^"]*"|[^,}]+)/).to_h { |key, value| [key.to_sym, unmark(value.strip)] }
        end

        # `read`, not `unmark`, until a where-clause's literal NUMBER and a
        # String field's own text collided the same way an object literal
        # and a symbol argument already had — see `read`'s own comment. A
        # where-clause's value now needs everything unmark reads : object
        # literals and symbols for the reason `read` already handled, and
        # numbers/booleans for gt/gte/lt/lte to compare against at all.
        def where_clause(clause)
          QuerySpecification::Common::WhereClause.new(
            field: clause[:field], op: clause[:op].to_sym, value: unmark(clause[:value])
          )
        end

        def order_by(declared)
          return nil unless declared

          QuerySpecification::Common::OrderBy.new(
            field: declared[:field], direction: declared[:direction].to_sym
          )
        end

        def limit(declared)
          return nil unless declared

          QuerySpecification::Common::LimitSpec.new(value: read(declared[:value]))
        end

        # EVERY OTHER SPECIFICATION OPTION, from one table.
        #
        # Each entry names the struct and which of its members carry a value that was
        # `render_value`d (a Symbol marked with a colon) rather than plain text. A
        # ninth option is one row here and nothing else — the language already holds
        # it, because it holds options as an open map rather than a field each.
        OPTIONS = {
          offset:         [QuerySpecification::Common::OffsetSpec,        %i[value]],
          cursor:         [QuerySpecification::Common::CursorSpec,        %i[value]],
          null_semantics: [QuerySpecification::Common::NullSemantics,     []],
          authorization:  [QuerySpecification::Common::AuthorizationSpec, %i[policy tenant]],
          consistency:    [QuerySpecification::Common::ConsistencySpec,   %i[timeout]],
          freshness:      [QuerySpecification::Common::FreshnessSpec,     %i[max_age]],
          inspection:     [QuerySpecification::Common::InspectionSpec,    []]
        }.freeze

        # `mode` and `policy` are read as symbols because the DSL declares them that
        # way — `nulls :last`, `authorize :customer_access` — and `to_h` spells them
        # with `to_s`, so the colon is not there to strip.
        SYMBOLIC = %i[mode policy tenant].freeze

        def option(name, declared)
          return nil if declared.nil?

          holder, marked = OPTIONS.fetch(name)
          holder.new(**Hash(declared).to_h { |key, value| [key, option_value(key, value, marked)] })
        end

        def option_value(key, value, marked)
          return nil               if value.nil?
          return read(value)       if marked.include?(key)
          return value.to_sym      if SYMBOLIC.include?(key)

          value
        end

        # A repeated option — an index hint per occurrence.
        def index_hints(declared)
          Array(declared).map { |hint| QuerySpecification::Common::IndexHint.new(name: hint[:name].to_sym) }
        end
      end
    end
  end
end
