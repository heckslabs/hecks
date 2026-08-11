require_relative "../bluebook/meta_validator"

module Hecksagain
  module Interview
    # A PROPOSAL, LOWERED INTO A DISPATCH.
    #
    # `Interview::Proposal` deliberately carries no structured "subject" or
    # "type" of its own — see interview.bluebook's own comment on
    # `Argument`: a proposal is a verb plus a flat list of
    # `{name, field, value}` rows, because that is the one shape every
    # dispatch in this language already reduces to (`Query::AskOption`,
    # `Wiring::Setting`, a closed set's own `member` pairs — no value
    # object can hold a map, so a head's own list is how this language
    # always says "arguments"). Whoever crafts a proposal (today: a
    # human; later: `Ports::Agent#interpret`) already decided the SHAPE —
    # which argument is bare (a reference, an `id:`) and which is
    # wrapped (`field: "value"` naming the field inside a value object) —
    # the same split `interview.bluebook`'s own comment on `Argument`
    # names. What this class adds is the one thing a proposal-writer
    # should not have to get right by hand: the SCALAR TYPE inside a
    # wrapped field (an `Integer`, a `TrueClass`/`FalseClass`, or plain
    # text), read off the language's own IR rather than guessed — a
    # `Proposal::Argument#value` is always a String (interview.bluebook
    # declares it that way, the honest shape for something typed into a
    # form or said in a sentence), and `Value::Coercion#check_numeric_fields`
    # refuses a string where a real `Integer`/`Float` is required, no
    # coercion happening at that layer (the same rule forms.rb's own
    # `Params.extract` was built against).
    class Lowering
      # A proposal that cannot be lowered at all — names a category or
      # verb the language does not declare, or a row shape nothing in
      # the language could ever have produced. Distinct from a REFUSAL:
      # `Session#offer` reports what the LANGUAGE said no to; this is
      # what fires when the PROPOSAL RECORD itself is malformed, before
      # any dispatch is attempted.
      MalformedProposal = Class.new(StandardError)

      def initialize(grammar_registry: Bluebook::MetaValidator.grammar_registry)
        @meta = grammar_registry.bluebook("Bluebook")
      end

      # THE REAL ENTRY POINT — a `Proposal` handle (or anything answering
      # `#verb`/`#arguments` the same shape the door hands back:
      # `Runtime::Value`s, `.value`/`.to_h` throughout). Kept separate
      # from `#lower` so the core transform stays testable against plain
      # hashes, with no domain record needed to exercise it.
      def lower_proposal(proposal)
        lower(proposal.verb.value, proposal.arguments.map(&:to_h))
      end

      # `verb` — "Bluebook::Aggregate.Attribute". `arguments` — an array
      # of `{name:, field:, value:}` (string values throughout; symbol or
      # string keys, either — a plain hash off `spec` and a `Value#to_h`
      # off a real record both work unchanged).
      #
      # Returns `[verb, args]`, ready for `Session#offer(verb, **args)`.
      def lower(verb, arguments)
        category, action = split(verb)
        aggregate, command = command_for(category, action)

        grouped = Hash.new { |rows, name| rows[name] = [] }
        arguments.each { |row| grouped[name_of(row)] << row }

        args = grouped.transform_values { |rows| built_value(aggregate, command, rows) }
        [verb, args]
      end

      private

      # "Bluebook::Aggregate.Attribute" -> ["Aggregate", "Attribute"]. Not
      # a general verb parser — every verb this class ever receives is one
      # `Plan#verbs` itself would produce (`"Bluebook::#{name}.#{verb}"`),
      # so a domain name other than "Bluebook" or a dotted (port/entity)
      # tail is a malformed proposal, not a shape this needs to read.
      def split(verb)
        domain, rest = verb.to_s.split("::", 2)
        raise MalformedProposal, "#{verb.inspect} is not Bluebook::Category.Verb-shaped" unless domain == "Bluebook" && rest

        category, action = rest.split(".", 2)
        raise MalformedProposal, "#{verb.inspect} is not Bluebook::Category.Verb-shaped" unless category && action

        [category, action]
      end

      def command_for(category, action)
        aggregate = @meta.aggregate(category) or
          raise MalformedProposal, "#{category.inspect} is not a category the language declares"

        command = aggregate.command(action) or
          raise MalformedProposal, "#{category} declares no #{action.inspect} command"

        [aggregate, command]
      end

      def name_of(row)  = field_of(row, :name).to_sym
      def field_of(row, key) = (row[key] || row[key.to_s]).to_s

      # ONE ARGUMENT, BUILT FROM ITS OWN ROW(S). Almost always one row.
      # More than one under the same `name` is a MULTI-FIELD value-object
      # argument, split across several `Supply` calls the same way a
      # command with a `{cadence:, retention_months:, paper_fee_cents:}`
      # closed-set argument would need to be, if this language's own
      # commands ever declared one (none do today; supported because
      # nothing about the shape says they couldn't).
      def built_value(aggregate, command, rows)
        bare, fielded = rows.partition { |row| field_of(row, :field).empty? }
        if bare.any?
          raise MalformedProposal, "an argument mixes a bare value with fielded ones" if fielded.any? || bare.size > 1

          return field_of(bare.first, :value)
        end

        attribute = command.attribute(name_of(rows.first))
        fielded.each_with_object({}) do |row, fields|
          field = field_of(row, :field).to_sym
          fields[field] = coerce(aggregate, attribute, field, field_of(row, :value))
        end
      end

      # THE ONE PLACE A STRING BECOMES WHAT THE LANGUAGE ACTUALLY WANTS.
      #
      # Every case here is one of `IR::Attribute::PRIMITIVES` — the
      # language's own closed list of scalar types an attribute may
      # bottom out at — not a guess about which ones an interview will
      # eventually need. Measured, not assumed: today only `Integer` is
      # real (`ValueObject::RowCount` — `given("a closed set admits a
      # member") { rows.value > 0 }`, which a bare string `"3"` fails
      # with `TypeMismatch` while a real `3` passes, confirmed against a
      # live dispatch). The language declares no `Float`-typed field and
      # spells its OWN flags as `String`-typed value objects
      # (`ListFlag { value: String }`, "true"/"false" as text —
      # `Reconstruction` is what turns that back into a real boolean, on
      # READ, not here on write) — but `Float`/`TrueClass`/`FalseClass`
      # stay in this table anyway, because the alternative is a SECOND,
      # narrower copy of `PRIMITIVES` that silently stops matching the
      # moment the language adds a field of one of those types, and
      # nothing would fail loudly to say so.
      def coerce(aggregate, attribute, field, raw)
        case scalar_type_of(aggregate, attribute, field)
        when "Integer" then Integer(raw)
        when "Float"   then Float(raw)
        when "TrueClass", "FalseClass" then %w[true 1].include?(raw)
        else raw
        end
      rescue ArgumentError
        raw # "not really a number after all" is the LANGUAGE's refusal to make, not this class's
      end

      # An argument's declared TYPE names a value object ("ListFlag"),
      # declared on the SAME AGGREGATE as the command itself (a value
      # object belongs to one aggregate — `IR::Aggregate#value_object`,
      # never the chapter's own `IR::Bluebook`, which holds no such
      # lookup at all). Its own `field` then names one of THAT value
      # object's attributes ("value"), and that attribute's own type is
      # the actual Ruby primitive (`TrueClass`) coercion needs. One hop,
      # read off the same IR `Value::Coercion` itself walks — never
      # restated as a second table of "which argument means what," which
      # is exactly the kind of copy that drifts the moment the language
      # adds a new one.
      def scalar_type_of(aggregate, attribute, field)
        return nil unless attribute

        value_object = aggregate.value_object(attribute.type.to_s)
        value_object&.attribute(field)&.type
      end
    end
  end
end
