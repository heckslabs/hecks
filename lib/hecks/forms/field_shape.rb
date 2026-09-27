require_relative "../vocabulary"
require_relative "../bluebook/attribute"
require_relative "../naming"
require_relative "value_object_shape"

module Hecks
  # The forms surface: the `expose` DSL, the IR->HTML renderers and the Rack app (see forms.rb).
  module Forms
    # One resolved field, ready for a renderer. A leaf carries `kind`/`options`; a `:group`
    # or `:list` carries `children`. `path` is the dotted path (`"amount.cents"`) that
    # `Params.extract` walks back apart on submit.
    Field = Struct.new(
      :path, :label, :kind, :html_type, :options, :children, :default, :optional,
      :pattern, :step, :help, :target_aggregate, keyword_init: true
    ) do
      def leaf? = kind != :group && kind != :list

      def optional? = optional

      def required? = !optional
    end

    # Turns a wire-spelled field or path segment into a label or legend.
    module Humanize
      # "daily_limit" -> "Daily limit"; only the last segment of a dotted path is used.
      def self.label(text)
        # Split on "." alone: an underscore is a word break within a segment, not a path hop.
        segment = text.to_s.split(".").last.to_s
        return segment if segment.empty?

        Naming.words(segment)
      end

      # "amount.cents" -> "Amount → Cents", for a fieldset legend spanning several hops.
      def self.breadcrumb(path)
        path.to_s.split(".").map { |part| label(part) }.join(" → ")
      end
    end

    # Attribute -> Field: the one mapping every form renderer reads instead of re-deriving.
    module FieldShape
      PRIMITIVES = Bluebook::Attribute::PRIMITIVES

      # Resolves one declared attribute into the field a form renders for it.
      #
      # `aggregate` owns the attribute and is needed to resolve `reference_to`, `admits:`
      # and same-chapter value objects; `path` is the dotted path reached so far.
      #
      # @param attribute [Bluebook::Attribute]
      # @param aggregate [Bluebook::Aggregate]
      # @param path [String]
      # @return [Forms::Field] a single-attribute value object resolves to its inner leaf,
      #   so the returned path may be longer than `path`
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

      def self.list_field(attribute, aggregate, path)
        # The scalar one element would take; `list:` is the only thing that differs.
        scalar = Bluebook::Attribute.new(
          name: attribute.name, type: attribute.type, list: false,
          default: nil, optional: true, pattern: attribute.pattern, admits: attribute.admits
        )
        Field.new(path: path, label: Humanize.label(path), kind: :list, optional: attribute.optional?,
                  children: [resolve(scalar, aggregate: aggregate, path: path)])
      end

      def self.reference_field(attribute, common)
        target = attribute.type.resolve
        Field.new(**common, kind: :reference, html_type: "text", target_aggregate: target,
                            help: if target
                                    "References an existing #{target.hecks_name} by id."
                                  else
                                    "References an aggregate in another domain — enter its id."
                                  end)
      end

      # Mirrors Runtime::Value::Admission#admitted_members (same split, chapter walk and
      # discriminant rule) so a `<select>` never offers a member the runtime would refuse.
      def self.admitted_field(attribute, aggregate, common)
        set_aggregate_name, set_name = attribute.admits.to_s.split("::", 2)
        chapter = aggregate.hecks_owner
        set = set_name && chapter&.aggregate(set_aggregate_name)&.value_object(set_name)
        # undeclared — refuse-at-dispatch stays the backstop
        return primitive_field(attribute, common) unless set

        options = select_or_radio(common, closed_set_options(set))
        # A value-object-typed attribute still needs the ".value" hop that
        # `Value::Coercion#fields_for` expects, even though `admits:` names a set elsewhere.
        own_shape = own_value_object(attribute, aggregate)
        inner = own_shape && ValueObjectShape.sole_attribute(own_shape)
        return options unless inner

        options.path = "#{common[:path]}.#{inner.name}"
        options
      end

      def self.own_value_object(attribute, aggregate)
        aggregate.value_object(attribute.type) || cross_aggregate_value_object(aggregate, attribute.type)
      end

      def self.value_object_field(attribute, aggregate, common)
        shape = own_value_object(attribute, aggregate)
        return primitive_field(attribute, common) unless shape

        return closed_set_field(shape, common) if shape.closed_set?
        return money_field(shape, common) if ValueObjectShape.money?(shape)

        # A single-attribute value object names a scalar, not a group: unwrap it so the form
        # asks for one thing and the inner attribute's own pattern drives the input type.
        if (inner = ValueObjectShape.sole_attribute(shape))
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

      # A member's discriminant is the value object's first attribute.
      def self.closed_set_options(value_object)
        discriminant = value_object.attributes.first.name
        value_object.members.map { |member| member[discriminant].to_s }
      end

      # A `one_of` shape is always single-attribute, so the path always gains the
      # discriminant hop; `admitted_field` must branch because its set may be multi-field.
      def self.closed_set_field(shape, common)
        discriminant = shape.attributes.first.name
        select_or_radio(common.merge(path: "#{common[:path]}.#{discriminant}"), closed_set_options(shape))
      end

      # Radio buttons for four or fewer options, a `<select>` beyond that.
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

      # Vocabulary::FieldHint rows (language/bluebook/vocabulary.bluebook), matched
      # case-insensitively. bin/project_field_hints writes the Rust host's copy from the same rows.
      HINTS = Hecks::Vocabulary.rows("FieldHint")
                               .to_h { |row| [row["name"], Regexp.new(row["pattern"], Regexp::IGNORECASE)] }
                               .freeze
      EMAIL_HINT    = HINTS.fetch("email")
      URL_HINT      = HINTS.fetch("url")
      TEL_HINT      = HINTS.fetch("tel")
      TEXTAREA_HINT = HINTS.fetch("textarea")

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
