require_relative "../vocabulary"
require_relative "../bluebook/attribute"
require_relative "../naming"
require_relative "value_object_shape"

module Hecks
  module Forms
    # One resolved field, ready for a renderer to turn into markup. A leaf
    # scalar carries `kind`/`options`/etc; a `:group` or `:list` carries
    # `children` instead and nothing else on itself.
    #
    # `path` is the dotted field path this attribute is reached at —
    # `"email.address"`, `"amount.cents"` — the same convention the language
    # already uses for a query's own cross-object `where` clauses
    # (`where(:"customer.status" => ...)`), not a fresh one invented here. A
    # command receives its arguments as nested hashes
    # (`email: {address: "..."}`), so `Params.extract` (params.rb) walks
    # this same dotted spelling back apart on submit — one convention, two
    # directions.
    Field = Struct.new(
      :path, :label, :kind, :html_type, :options, :children, :default, :optional,
      :pattern, :step, :help, :target_aggregate, keyword_init: true
    ) do
      # Tells whether this field holds a value itself rather than carrying `children`.
      #
      # @return [Boolean] false for a `:group` or `:list`, true for every other kind,
      #   `:money` included
      def leaf? = kind != :group && kind != :list

      # Tells whether a submission may leave this field blank.
      #
      # @return [Boolean, nil] the `optional` member as given; nil when the field was built
      #   without one, which reads as required
      def optional? = optional

      # Tells whether a submission must fill this field in.
      #
      # @return [Boolean] true unless `optional` was set truthy
      def required? = !optional
    end

    # Turns a wire-spelled field or path segment into the plain-English text
    # `FieldShape` embeds as a `Field`'s label or a group's legend.
    module Humanize
      # Humanizes the last segment of a field name or dotted path into sentence-case words.
      #
      # "given" -> "Given", "daily_limit" -> "Daily limit", "end_to_end" ->
      # "End to end" — the label a plain reader wants, not the wire spelling.
      #
      # @param text [String, Symbol, nil] a field name or dotted path, such as
      #   `"amount.cents"`; only the part after the last `"."` is used
      # @return [String] the humanized words, or `""` when `text` is nil or empty
      def self.label(text)
        # Split on "." first, alone, to take only the last path segment —
        # "daily_limit" is one segment (the underscore is a word break
        # inside it, not a path hop) and must keep both its words; only a
        # genuinely dotted path ("amount.cents") drops everything before
        # the last ".".
        segment = text.to_s.split(".").last.to_s
        return segment if segment.empty?

        # The word split itself is `Naming.words` — the one humanizer,
        # shared with the glossary projection.
        Naming.words(segment)
      end

      # Humanizes every segment of a dotted path and joins them with " → ".
      #
      # The full dotted path, each segment humanized and joined with
      # " → " for a fieldset legend spanning more than one hop
      # ("Amount → Cents") — a group's own legend, not a leaf's label.
      #
      # @param path [String, Symbol, nil] a dotted field path, such as `"amount.cents"`
      # @return [String] the humanized trail, or `""` when `path` is nil or empty
      def self.breadcrumb(path)
        path.to_s.split(".").map { |part| label(part) }.join(" → ")
      end
    end

    # Attribute -> Field. The one mapping every renderer in this
    # directory reads instead of re-deriving its own — see
    # docs/command-form-and-query-form-bluebook.md's survey of the gap this closes (the
    # prior generic-console attempt fell back to `type="text"` for anything
    # that wasn't a number or an enum; a `pattern` naming an email shape, or a
    # closed set another aggregate declares, went unread).
    module FieldShape
      PRIMITIVES = Bluebook::Attribute::PRIMITIVES

      # Resolves one declared attribute into the field a form renders for it, choosing the
      # input kind from the attribute's type, pattern, `admits:` set and value-object shape.
      #
      # `aggregate:` is the Aggregate that owns this attribute (a
      # command's, a query's, or — recursively — a value object's) —
      # needed to resolve `reference_to`, `admits:`, and a same-chapter
      # value object by name. `path:` defaults to the attribute's own name;
      # a caller resolving a nested value object's attribute passes the
      # dotted path so far.
      #
      # @param attribute [Bluebook::Attribute] the attribute to build a field for
      # @param aggregate [Bluebook::Aggregate] the aggregate that owns the attribute
      # @param path [String] dotted field path the attribute is reached at
      # @return [Forms::Field] the resolved field; a single-attribute value object resolves
      #   to its inner leaf, so the returned path may be longer than `path`
      # @raise [Bluebook::DSL::Malformed] if a `reference_to` attribute cannot say which
      #   aggregate declares it
      def self.resolve(attribute, aggregate:, path: attribute.name.to_s)
        return list_field(attribute, aggregate, path) if attribute.list?

        common = { path: path, label: Humanize.label(path), default: attribute.default,
                   optional: attribute.optional?, pattern: attribute.pattern }

        return reference_field(attribute, common) if attribute.reference?
        return admitted_field(attribute, aggregate, common) if attribute.admits
        return value_object_field(attribute, aggregate, common) unless PRIMITIVES.include?(attribute.type)

        primitive_field(attribute, common)
      end

      # Builds the `:list` field for a `list_of` attribute, carrying as its one child the field
      # a single element would resolve to.
      #
      # @param attribute [Bluebook::Attribute] the list attribute
      # @param aggregate [Bluebook::Aggregate] the aggregate that owns the attribute
      # @param path [String] dotted field path the list is reached at
      # @return [Forms::Field] a `:list` field whose `children` holds exactly one element field
      # @raise [Bluebook::DSL::Malformed] if the element is a `reference_to` that cannot say
      #   which aggregate declares it
      def self.list_field(attribute, aggregate, path)
        # The scalar shape one element of this list would take, so a
        # renderer can say what belongs on each line without a second
        # mapping table. `list:` is the only thing that differs.
        scalar = Bluebook::Attribute.new(
          name: attribute.name, type: attribute.type, list: false,
          default: nil, optional: true, pattern: attribute.pattern, admits: attribute.admits
        )
        Field.new(path: path, label: Humanize.label(path), kind: :list, optional: attribute.optional?,
                  children: [resolve(scalar, aggregate: aggregate, path: path)])
      end

      # Builds the `:reference` field for a `reference_to` attribute, remembering the target
      # aggregate so a renderer can offer its records.
      #
      # @param attribute [Bluebook::Attribute] an attribute whose type is a
      #   `Bluebook::Reference`
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @return [Forms::Field] a `:reference` field; its `target_aggregate` is nil when the
      #   target belongs to a domain that is not loaded
      # @raise [Bluebook::DSL::Malformed] if the reference cannot say which aggregate
      #   declares it
      def self.reference_field(attribute, common)
        target = attribute.type.resolve
        Field.new(**common, kind: :reference, html_type: "text", target_aggregate: target,
                            help: if target
                                    "References an existing #{target.hecks_name} by id."
                                  else
                                    "References an aggregate in another domain — enter its id."
                                  end)
      end

      # Builds the radio or select field for an attribute whose `admits:` names a closed set,
      # offering exactly that set's members.
      #
      # `admits:` names a closed set declared elsewhere (`"Account::
      # LedgerDirection"`) that the value must belong to — see
      # Runtime::Value::Admission#admitted_members, which this mirrors
      # exactly (same split, same chapter walk, same discriminant rule) so
      # a rendered `<select>` never offers a member the runtime would then
      # refuse.
      #
      # @param attribute [Bluebook::Attribute] an attribute declaring `admits:`
      # @param aggregate [Bluebook::Aggregate] the aggregate that owns the attribute; its
      #   chapter is searched for the named set
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @return [Forms::Field] a `:radio` or `:select` field, its path extended by one hop
      #   when the attribute's own type is a single-attribute value object; a plain
      #   primitive field when the named set is not declared
      def self.admitted_field(attribute, aggregate, common)
        set_aggregate_name, set_name = attribute.admits.to_s.split("::", 2)
        chapter = aggregate.hecks_owner
        set = set_name && chapter&.aggregate(set_aggregate_name)&.value_object(set_name)
        # undeclared — refuse-at-dispatch stays the backstop
        return primitive_field(attribute, common) unless set

        options = select_or_radio(common, closed_set_options(set))
        # The attribute's own type still has to be built the shape coercion
        # expects (`Value::Coercion#fields_for` refuses anything that
        # isn't a Hash or a Value for a value-object-typed attribute) — a
        # plain String attribute stays a bare scalar, but a value object
        # like `MovementDirection { value }` still needs the ".value" hop
        # even though the set it's checked against (`admits:`) is declared
        # somewhere else entirely. Same unwrap `value_object_field` does,
        # kept separate because an admitted set changes the options, not
        # which field the hop lands on.
        own_shape = own_value_object(attribute, aggregate)
        inner = own_shape && ValueObjectShape.sole_attribute(own_shape)
        return options unless inner

        options.path = "#{common[:path]}.#{inner.name}"
        options
      end

      # Finds the value object an attribute's type names, looking on the owning aggregate
      # first and then on every other aggregate of the same chapter.
      #
      # @param attribute [Bluebook::Attribute] the attribute whose type names a value object
      # @param aggregate [Bluebook::Aggregate] the aggregate that owns the attribute
      # @return [Bluebook::ValueObject, nil] the declared shape, or nil when no aggregate in
      #   the chapter declares a value object of that name
      def self.own_value_object(attribute, aggregate)
        aggregate.value_object(attribute.type) || cross_aggregate_value_object(aggregate, attribute.type)
      end

      # Builds the field for an attribute typed as a value object: a closed-set choice, a
      # money pair, the unwrapped inner leaf of a single-attribute shape, or a group.
      #
      # @param attribute [Bluebook::Attribute] an attribute whose type is not a primitive
      # @param aggregate [Bluebook::Aggregate] the aggregate that owns the attribute
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @return [Forms::Field] the resolved field; a plain primitive field when the named
      #   value object is not declared anywhere in the chapter
      # @raise [Bluebook::DSL::Malformed] if a nested `reference_to` attribute cannot say
      #   which aggregate declares it
      def self.value_object_field(attribute, aggregate, common)
        shape = own_value_object(attribute, aggregate)
        return primitive_field(attribute, common) unless shape

        return closed_set_field(shape, common) if shape.closed_set?
        return money_field(shape, common) if ValueObjectShape.money?(shape)

        # A single-attribute value object (EmailAddress{address}, CustomerNumber{value})
        # is a name for a scalar, not a genuine group — unwrap it so the form
        # asks for one thing ("Email address") instead of a one-item fieldset,
        # and so the inner attribute's own pattern (the real email regex,
        # declared on `address`, not on the outer `email` attribute) drives
        # the input type. [[feedback_name_the_scalar_field]] says the same
        # thing about Ruby call sites; a form asks the identical question.
        if (inner = ValueObjectShape.sole_attribute(shape))
          return resolve(inner, aggregate: aggregate, path: "#{common[:path]}.#{inner.name}")
                 .tap { |field| field.optional = common[:optional] || field.optional }
        end

        group_field(shape, aggregate, common)
      end

      # Searches every aggregate of the owning chapter for a value object by name, so a shape
      # declared on a sibling aggregate still resolves.
      #
      # @param aggregate [Bluebook::Aggregate] any aggregate of the chapter to search
      # @param type_name [String] name of the value object, as `Bluebook::Attribute#type`
      #   spells it
      # @return [Bluebook::ValueObject, nil] the first match in aggregate declaration order, or
      #   nil when none declares it or the aggregate has no owning chapter
      def self.cross_aggregate_value_object(aggregate, type_name)
        aggregate.hecks_owner&.aggregates&.each do |sibling|
          found = sibling.value_object(type_name)
          return found if found
        end
        nil
      end

      # Builds the `:group` field for a multi-attribute value object, resolving each of its
      # attributes one path hop below the group.
      #
      # @param shape [Bluebook::ValueObject] the value object whose attributes become children
      # @param aggregate [Bluebook::Aggregate] the aggregate the nested attributes resolve
      #   against
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares; only
      #   `:path`, `:label` and `:optional` are read
      # @return [Forms::Field] a `:group` field with one child per attribute of `shape`
      # @raise [Bluebook::DSL::Malformed] if a nested `reference_to` attribute cannot say
      #   which aggregate declares it
      def self.group_field(shape, aggregate, common)
        children = shape.attributes.map { |inner| resolve(inner, aggregate: aggregate, path: "#{common[:path]}.#{inner.name}") }
        Field.new(path: common[:path], label: common[:label], kind: :group, optional: common[:optional], children: children)
      end

      # Builds the `:money` field for a `cents`/`currency` value object: a required-or-not
      # whole-cents number input beside an always-optional currency code.
      #
      # @param shape [Bluebook::ValueObject] the money-shaped value object, read for the
      #   declared defaults of `cents` and `currency`
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares; only
      #   `:path`, `:label` and `:optional` are read
      # @return [Forms::Field] a `:money` field whose children are the `cents` and `currency`
      #   leaves, the currency defaulting to `"USD"` when the shape declares none
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

      # Lists a closed set's members by their discriminant — the value object's first
      # attribute — as the strings a form offers.
      #
      # @param value_object [Bluebook::ValueObject] a closed-set (`one_of`) value object
      # @return [Array<String>] one discriminant value per declared member, in declaration
      #   order; `[]` when the shape declares no members
      def self.closed_set_options(value_object)
        discriminant = value_object.attributes.first.name
        value_object.members.map { |member| member[discriminant].to_s }
      end

      # Builds the radio or select field for an attribute typed as a closed set, its path
      # extended by the set's discriminant attribute.
      #
      # A `one_of` shape (`AccountKind{name}`, `LedgerDirection{value}`) is
      # always single-attribute in this language — the discriminant is the
      # whole value object — so the field's own path always gains that one
      # hop; nothing to branch on the way `admitted_field` has to (a set
      # named by `admits:` may sit on a multi-field value object it doesn't
      # itself define the members of).
      #
      # @param shape [Bluebook::ValueObject] the closed-set value object
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @return [Forms::Field] a `:radio` or `:select` field offering the set's members
      def self.closed_set_field(shape, common)
        discriminant = shape.attributes.first.name
        select_or_radio(common.merge(path: "#{common[:path]}.#{discriminant}"), closed_set_options(shape))
      end

      # Builds a choice field over fixed options, as radio buttons for four or fewer and a
      # `<select>` beyond that.
      #
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @param options [Array<String>] the values offered; each is its own label
      # @return [Forms::Field] a `:radio` or `:select` field whose `options` are
      #   `[value, label]` pairs
      def self.select_or_radio(common, options)
        kind = options.size <= 4 ? :radio : :select
        Field.new(**common, kind: kind, html_type: "text", options: options.map { |value| [value, value] })
      end

      # Builds the leaf field for a primitive-typed attribute: a number input for `Integer`
      # and `Float`, a checkbox for a boolean, and a text-family input for anything else.
      #
      # @param attribute [Bluebook::Attribute] the attribute whose type picks the input
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @return [Forms::Field] a `:number`, `:boolean`, `:text` or `:textarea` leaf; an
      #   `Integer` carries `step` `"1"`, a `Float` `"any"`
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

      # Vocabulary::FieldHint (language/bluebook/vocabulary.bluebook), read
      # off the generated table: `pattern` is the regex source, matched
      # case-insensitively. bin/project_field_hints writes the Rust host's
      # copy from the same rows.
      HINTS = Hecks::Vocabulary.rows("FieldHint")
                               .to_h { |row| [row["name"], Regexp.new(row["pattern"], Regexp::IGNORECASE)] }
                               .freeze
      EMAIL_HINT    = HINTS.fetch("email")
      URL_HINT      = HINTS.fetch("url")
      TEL_HINT      = HINTS.fetch("tel")
      TEXTAREA_HINT = HINTS.fetch("textarea")

      # Builds a text-family leaf, picking `email`, `url`, `tel` or plain `text` from the
      # attribute's pattern and the `FieldHint` name patterns, and a textarea for a
      # long-text name.
      #
      # @param attribute [Bluebook::Attribute] the attribute whose name and pattern are read
      # @param common [Hash{Symbol => Object}] the `Field` members every kind shares, keyed
      #   `:path`, `:label`, `:default`, `:optional`, `:pattern`
      # @return [Forms::Field] a `:text` leaf, or `:textarea` when the input type is plain
      #   `"text"` and the name matches `TEXTAREA_HINT`
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
