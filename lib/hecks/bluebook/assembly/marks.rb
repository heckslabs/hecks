module Hecks
  module Bluebook
    class Assembly
      # Reads the leaf shapes of an assembly's `to_h` export back into IR objects.
      # Each method inverts one textual spelling, so types are recovered, not just strings.
      module Marks
        module_function

        # `Attribute#to_h` spells a type with `to_s`, so a reference arrives as
        # "Reference<Customer>" and has to become an edge again.
        def attribute(field)
          type = field[:type].to_s
          target = type[/\AReference<(.+)>\z/, 1]

          Attribute.new(name: field[:name], type: target ? Reference.new(target) : type, **attribute_options(field))
        end

        # Every registry bluebook is a round-trip product, so a fact dropped here is a fact
        # the language cannot state about itself. `admits` is not on `to_h`, but the grammar
        # registry keeps the assembled graph and downstream projections read the link off it.
        def attribute_options(field)
          {
            list:         field[:list] ? true : false,
            default:      field[:default],
            optional:     field[:optional] ? true : false,
            pattern:      field[:pattern],
            admits:       field[:admits],
            relationship: field[:relationship]
          }
        end

        # A head's field and a verb's argument are separate verbs sharing one IR class.
        def shape_field(field) = attribute(field)

        # One identity part, as the String path `identity_paths` splits.
        def identity_path(part) = part[:value].to_s

        # A member's fields, an open map, so the pairs arrive as a list.
        # Values are unmarked because `ValueObject#to_h` spells them with `to_s`.
        def member(pairs)
          pairs.to_h { |key, value| [key.to_sym, unmark_scalar(value)] }
        end

        # A read model's gathered head; `as` is a Symbol because `ReadModel#to_h` spells it `to_s`.
        def head(row)
          row.to_h { |key, value| [key.to_sym, key.to_sym == :as ? value.to_sym : value] }
        end

        # Matches the builder's native `{field: :symbol}` shape.
        def group_by_field(row) = { field: row[:field].to_sym }

        # Reads a member's scalar back from text. Unlike `read`, a bare word stays a
        # String, because a closed set admits words far more often than symbols.
        def unmark_scalar(value)
          text = value.to_s
          return true       if text == "true"
          return false      if text == "false"
          return text.to_i  if text.match?(/\A-?\d+\z/)
          return text.to_f  if text.match?(/\A-?\d+\.\d+\z/)

          text
        end

        # A saga's argument bindings; Literal marks a Symbol with a leading colon.
        def bindings(with) = Array(with).to_h { |key, value| [key.to_sym, read(value)] }

        # Builds one aggregate or value object invariant from its declared row.
        # `Expression::Evaluator` parses `canonical` on demand.
        def invariant(rule)
          Invariant.new(description: rule[:description], canonical: rule[:canonical])
        end

        # Builds one command precondition from its declared row.
        def given(rule)
          Given.new(description: rule[:description], canonical: rule[:canonical])
        end

        # One outside fact a command needs, as the Symbol `Command#needs` holds.
        def need(row) = row[:fact].to_sym

        # All three fields are identifiers, unlike Invariant/Given's free text, so they
        # come back as Symbols.
        def projected_field(row)
          ProjectedField.new(name: row[:name].to_sym, reference: row[:reference].to_sym,
                             remote_field: row[:remote_field].to_sym)
        end

        # `Mutation#to_h` branches on the operation, so this does too.
        # An append binds several fields, each an argument (a Symbol) or a literal.
        def mutation(change)
          target = change[:target].to_sym
          op     = change[:op].to_sym

          # `:delegate` and `:corrects` ride the same multi-binding shape as `:append`.
          return Mutation.new(target: target, op: op, source: appended(change[:fields])) if [:append, :delegate,
                                                                                             :corrects].include?(op)

          Mutation.new(target: target, op: op, source: classified(change[:source]))
        end

        # Reads an append mutation's field bindings back off their declared rows.
        def appended(fields)
          Array(fields).to_h { |field, source| [field.to_sym, read(source)] }
        end

        # A set reads one thing: an argument by name, or a literal by value.
        def classified(source)
          return nil if source.nil?

          case source[:kind].to_s
          when "argument" then source[:name].to_sym
          when "state"    then StateRef.new(source[:name].to_sym)
          when "expression" then Computed.new(source[:text])
          else source[:value]
          end
        end

        # Reads every literal field on the wire through `Literal`, so no second reader
        # can disagree about quoting. An object literal read as a plain string reaches
        # the runtime as inspect text, which coercion refuses, and the saga leg stalls.
        def read(value) = Literal.read(value)

        # `target:` is read straight off the wire, unconverted. A missing key reads
        # `nil` like an explicit `nil`, so older wire data needs no migration.
        def where_clause(clause)
          QuerySpecification::Common::WhereClause.new(
            field: clause[:field], op: clause[:op].to_sym, value: read(clause[:value]), target: clause[:target]
          )
        end

        # Builds a query's declared ordering, if it declares one.
        def order_by(declared)
          return nil unless declared

          QuerySpecification::Common::OrderBy.new(
            field: declared[:field], direction: declared[:direction].to_sym, target: declared[:target]
          )
        end

        # Builds a query's declared limit, if it declares one.
        def limit(declared)
          return nil unless declared

          QuerySpecification::Common::LimitSpec.new(value: read(declared[:value]), target: declared[:target])
        end

        # Every other specification option, from one table: the struct, and which of
        # its members carry a value that rode Literal's spelling.
        OPTIONS = {
          offset:         [QuerySpecification::Common::OffsetSpec,        %i[value]],
          cursor:         [QuerySpecification::Common::CursorSpec,        %i[value]],
          null_semantics: [QuerySpecification::Common::NullSemantics,     []],
          authorization:  [QuerySpecification::Common::AuthorizationSpec, %i[policy tenant]],
          inspection:     [QuerySpecification::Common::InspectionSpec,    []]
        }.freeze

        # The DSL declares these as symbols (`nulls :last`) and `to_h` spells them with
        # `to_s`, so they are converted back.
        SYMBOLIC = %i[mode policy tenant].freeze

        # Builds one query specification option from its declared row and `OPTIONS`.
        # @raise [KeyError] if `name` is not a key of `OPTIONS`
        def option(name, declared)
          return nil if declared.nil?

          holder, marked = OPTIONS.fetch(name)
          holder.new(**Hash(declared).to_h { |key, value| [key, option_value(key, value, marked)] })
        end

        # Reads one option member's declared value back to its native type.
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
