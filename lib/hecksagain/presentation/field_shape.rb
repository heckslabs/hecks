require_relative "../bluebook/ir/attribute"

module Hecksagain
  module Presentation
    # One resolved field, ready for a renderer to turn into markup. A LEAF
    # scalar carries `kind`/`options`/etc; a `:group` or `:list` carries
    # `children` instead and nothing else on itself.
    #
    # `path` is the DOTTED field path this attribute is reached at —
    # `"email.address"`, `"amount.cents"` — the same convention the language
    # already uses for a query's own cross-object `where` clauses
    # (`where(:"customer.status" => ...)`), not a fresh one invented here. A
    # command receives its arguments as nested hashes
    # (`email: {address: "..."}`), so `Params.unflatten` (params.rb) walks
    # this same dotted spelling back apart on submit — one convention, two
    # directions.
    Field = Struct.new(
      :path, :label, :kind, :html_type, :options, :children, :default, :optional,
      :pattern, :step, :help, :target_aggregate, keyword_init: true
    ) do
      def leaf? = kind != :group && kind != :list
      def optional? = optional
      def required? = !optional
    end

    module Humanize
      # "given" -> "Given", "daily_limit" -> "Daily limit", "end_to_end" ->
      # "End to end" — the label a plain reader wants, not the wire spelling.
      def self.label(text)
        # Split on "." FIRST, alone, to take only the last path segment —
        # "daily_limit" is one segment (the underscore is a word break
        # inside it, not a path hop) and must keep both its words; only a
        # genuinely dotted path ("amount.cents") drops everything before
        # the last ".".
        segment = text.to_s.split(".").last.to_s
        words = segment.split("_")
        return segment if words.empty?

        ([words.first.capitalize] + words.drop(1)).join(" ")
      end

      # The full dotted path, each segment humanized and joined with
      # " → " for a fieldset legend spanning more than one hop
      # ("Amount → Cents") — a group's own legend, not a leaf's label.
      def self.breadcrumb(path)
        path.to_s.split(".").map { |part| label(part) }.join(" → ")
      end
    end

    # IR::Attribute -> Field. The one mapping every renderer in this
    # directory reads instead of re-deriving its own — see
    # docs/presentation-bluebook.md's survey of the gap this closes (the
    # prior generic-console attempt fell back to `type="text"` for anything
    # that wasn't a number or an enum; a `pattern` naming an email shape, or a
    # closed set another aggregate declares, went unread).
    module FieldShape
      PRIMITIVES = Bluebook::IR::Attribute::PRIMITIVES

      # `aggregate:` is the IR::Aggregate that OWNS this attribute (a
      # command's, a query's, or — recursively — a value object's) —
      # needed to resolve `reference_to`, `admits:`, and a same-chapter
      # value object by name. `path:` defaults to the attribute's own name;
      # a caller resolving a nested value object's attribute passes the
      # dotted path so far.
      def self.resolve(attribute, aggregate:, path: attribute.name.to_s)
        return list_field(attribute, aggregate, path) if attribute.list?

        common = { path: path, label: Humanize.label(path), default: attribute.default,
                   optional: attribute.optional?, pattern: attribute.pattern }

        return reference_field(attribute, common) if attribute.reference?
        return admitted_field(attribute, aggregate, common) if attribute.admits
        return value_object_field(attribute, aggregate, common) unless PRIMITIVES.include?(attribute.type)

        primitive_field(attribute, common)
      end

      def self.list_field(attribute, aggregate, path)
        # The scalar shape one element of this list would take, so a
        # renderer can say what belongs on each line without a second
        # mapping table. `list:` is the only thing that differs.
        scalar = Bluebook::IR::Attribute.new(
          name: attribute.name, type: attribute.type, list: false,
          default: nil, optional: true, pattern: attribute.pattern, admits: attribute.admits
        )
        Field.new(path: path, label: Humanize.label(path), kind: :list, optional: attribute.optional?,
                  children: [resolve(scalar, aggregate: aggregate, path: path)])
      end

      def self.reference_field(attribute, common)
        target = attribute.type.resolve
        Field.new(**common, kind: :reference, html_type: "text", target_aggregate: target,
                  help: target ? "References an existing #{target.hecks_name} by id." :
                        "References an aggregate in another domain — enter its id.")
      end

      # `admits:` names a closed set declared ELSEWHERE (`"Account::
      # LedgerDirection"`) that the value must belong to — see
      # Runtime::Value::Admission#admitted_members, which this mirrors
      # exactly (same split, same chapter walk, same discriminant rule) so
      # a rendered `<select>` never offers a member the runtime would then
      # refuse.
      def self.admitted_field(attribute, aggregate, common)
        set_aggregate_name, set_name = attribute.admits.to_s.split("::", 2)
        chapter = aggregate.hecks_owner
        set = set_name && chapter&.aggregate(set_aggregate_name)&.value_object(set_name)
        return primitive_field(attribute, common) unless set # undeclared — refuse-at-dispatch stays the backstop

        options = select_or_radio(common, closed_set_options(set))
        # The attribute's OWN type still has to be built the shape coercion
        # expects (`Value::Coercion#fields_for` refuses anything that
        # isn't a Hash or a Value for a value-object-typed attribute) — a
        # plain String attribute stays a bare scalar, but a value object
        # like `MovementDirection { value }` still needs the ".value" hop
        # even though the SET it's checked against (`admits:`) is declared
        # somewhere else entirely. Same unwrap `value_object_field` does,
        # kept separate because an admitted set changes the OPTIONS, not
        # which field the hop lands on.
        own_shape = own_value_object(attribute, aggregate)
        return options unless own_shape && own_shape.attributes.size == 1

        options.path = "#{common[:path]}.#{own_shape.attributes.first.name}"
        options
      end

      def self.own_value_object(attribute, aggregate)
        aggregate.value_object(attribute.type) || cross_aggregate_value_object(aggregate, attribute.type)
      end

      def self.value_object_field(attribute, aggregate, common)
        shape = own_value_object(attribute, aggregate)
        return primitive_field(attribute, common) unless shape

        return closed_set_field(shape, common) if shape.closed_set?
        return money_field(shape, common) if money_shaped?(shape)

        # A single-attribute value object (EmailAddress{address}, CustomerNumber{value})
        # is a NAME for a scalar, not a genuine group — unwrap it so the form
        # asks for one thing ("Email address") instead of a one-item fieldset,
        # and so the inner attribute's OWN pattern (the real email regex,
        # declared on `address`, not on the outer `email` attribute) drives
        # the input type. [[feedback_name_the_scalar_field]] says the same
        # thing about Ruby call sites; a form asks the identical question.
        if shape.attributes.size == 1
          inner = shape.attributes.first
          return resolve(inner, aggregate: aggregate, path: "#{common[:path]}.#{inner.name}")
                 .tap { |field| field.optional = common[:optional] || field.optional }
        end

        group_field(shape, aggregate, common)
      end

      def self.cross_aggregate_value_object(aggregate, type_name)
        aggregate.hecks_owner&.aggregates&.each do |sibling|
          found = sibling.value_object(type_name)
          return found if found
        end
        nil
      end

      def self.group_field(shape, aggregate, common)
        children = shape.attributes.map { |inner| resolve(inner, aggregate: aggregate, path: "#{common[:path]}.#{inner.name}") }
        Field.new(path: common[:path], label: common[:label], kind: :group, optional: common[:optional], children: children)
      end

      def self.money_shaped?(shape)
        shape.attributes.map { |a| a.name }.sort == %i[cents currency]
      end

      def self.money_field(shape, common)
        cents = Field.new(path: "#{common[:path]}.cents", label: "Amount (cents)", kind: :number,
                           html_type: "number", step: "1", optional: common[:optional],
                           default: shape.attribute(:cents)&.default, help: "Whole cents — 1050 is $10.50.")
        currency = Field.new(path: "#{common[:path]}.currency", label: "Currency", kind: :text, html_type: "text",
                              optional: true, default: shape.attribute(:currency)&.default || "USD",
                              help: "Three-letter code.")
        Field.new(path: common[:path], label: common[:label], kind: :money, optional: common[:optional],
                  children: [cents, currency])
      end

      def self.closed_set_options(value_object)
        discriminant = value_object.attributes.first.name
        value_object.members.map { |member| member[discriminant].to_s }
      end

      # A `one_of` shape (`AccountKind{name}`, `LedgerDirection{value}`) is
      # ALWAYS single-attribute in this language — the discriminant IS the
      # whole value object — so the field's own path always gains that one
      # hop; nothing to branch on the way `admitted_field` has to (a set
      # named by `admits:` may sit on a multi-field value object it doesn't
      # itself define the members of).
      def self.closed_set_field(shape, common)
        discriminant = shape.attributes.first.name
        select_or_radio(common.merge(path: "#{common[:path]}.#{discriminant}"), closed_set_options(shape))
      end

      def self.select_or_radio(common, options)
        kind = options.size <= 4 ? :radio : :select
        Field.new(**common, kind: kind, html_type: "text", options: options.map { |value| [value, value] })
      end

      def self.primitive_field(attribute, common)
        case attribute.type.to_s
        when "Integer" then Field.new(**common, kind: :number, html_type: "number", step: "1")
        when "Float"   then Field.new(**common, kind: :number, html_type: "number", step: "any")
        when "TrueClass", "FalseClass"
          Field.new(**common, kind: :boolean, html_type: "checkbox")
        else
          text_field(attribute, common)
        end
      end

      EMAIL_HINT = /email/i
      URL_HINT   = /\b(url|uri|website|link)\b/i
      TEL_HINT   = /phone|\btel(ephone)?\b/i
      TEXTAREA_HINT = /\b(text|body|note|notes|description|message|comment)\b/i

      def self.text_field(attribute, common)
        name = attribute.name.to_s
        pattern = attribute.pattern.to_s
        html_type = if pattern.include?("@") || name.match?(EMAIL_HINT)
                      "email"
                    elsif pattern.match?(/https?/i) || name.match?(URL_HINT)
                      "url"
                    elsif name.match?(TEL_HINT)
                      "tel"
                    else
                      "text"
                    end
        kind = html_type == "text" && name.match?(TEXTAREA_HINT) ? :textarea : :text
        Field.new(**common, kind: kind, html_type: html_type)
      end
    end
  end
end
