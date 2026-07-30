module Hecksagain
  module Bluebook
    class Assembly
      # The leaf shapes an assembly reads, and the encodings it undoes.
      #
      # `to_h` spells things as text so a second runtime can read them, and every
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
            name:    field[:name],
            type:    target ? IR::Reference.new(target) : type,
            list:    field[:list] ? true : false,
            default: field[:default]
          )
        end
        alias shape_field attribute

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
        def read(value)
          text = value.to_s
          text.start_with?(":") ? text[1..].to_sym : text
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

        def where_clause(clause)
          QuerySpecification::Common::WhereClause.new(
            field: clause[:field], op: clause[:op].to_sym, value: read(clause[:value])
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
      end
    end
  end
end
