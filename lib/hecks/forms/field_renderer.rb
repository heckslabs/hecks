require_relative "html"
require_relative "field_shape"
require_relative "field_controls"
require_relative "../naming"

module Hecks
  module Forms
    # Renders a Field (field_shape.rb) as form markup, recursing into a group's children.
    # Shared by CommandFormRenderer (POST) and QueryFormRenderer (GET).
    module FieldRenderer
      # Renders one field, filling any held value back in.
      #
      # `reference_options` is built by the caller, since it needs a repository and
      # this module stays pure markup.
      def self.render(field, values: {}, errors: nil, reference_options: {})
        held = { values: values, errors: errors, reference_options: reference_options }
        case field.kind
        when :group  then group(field, held, tag: "fieldset")
        when :money  then group(field, held, tag: "fieldset", css: "money")
        when :list   then list(field, values, errors)
        else              leaf(field, values, errors, reference_options)
        end
      end

      # @param held [Hash] the `values:`, `errors:` and `reference_options:` each child renders with
      def self.group(field, held, tag:, css: nil)
        inner = field.children.map { |child| render(child, **held) }
        <<~HTML
          <#{tag}#{%( class="#{css}") if css}>
            <legend>#{Escape.html(field.label)}#{required_mark(field)}</legend>
            #{inner.join("\n")}
          </#{tag}>
        HTML
      end

      # One textarea, an element per line: the shape `Params.extract_list` reads back.
      def self.list(field, values, _errors)
        item = field.children.first
        list_head(field, item, Array(dig(values, field.path)).join("\n")) + list_tail(field, item)
      end

      def self.list_head(field, item, current)
        id = dom_id(field.path)
        <<~HTML
          <div class="field">
            <label for="#{id}">#{Escape.html(field.label)}#{required_mark(field)}</label>
            <textarea id="#{id}" name="#{Escape.attr(field.path)}"
              #{aria(field)} placeholder="one #{Escape.attr(item.label.downcase)} per line">#{Escape.html(current)}</textarea>
        HTML
      end

      def self.list_tail(field, item)
        <<~HTML
            <span class="help" id="#{dom_id(field.path)}-help">One #{Escape.html(item.label.downcase)} per line#{" — each line is one JSON object" unless item.leaf?}.</span>
          </div>
        HTML
      end

      def self.leaf(field, values, errors, reference_options)
        value = dig(values, field.path)
        error = errors && errors[field.path]
        wrap(field, control(field, value, reference_options), error)
      end

      def self.control(field, value, reference_options)
        case field.kind
        when :boolean   then Controls.checkbox(field, value)
        when :radio     then Controls.radio_group(field, value)
        when :select    then Controls.select(field, value)
        when :textarea  then Controls.textarea(field, value)
        when :reference then Controls.reference_select(field, value, reference_options[field.path])
        else Controls.input(field, value)
        end
      end

      # A :boolean gets no label here because `checkbox` renders its own beside the box.
      def self.wrap(field, body, error)
        <<~HTML
          <div class="field#{" has-error" if error}">
            #{%(<label for="#{dom_id(field.path)}">#{Escape.html(field.label)}#{required_mark(field)}</label>) unless field.kind == :boolean}
            #{body}
            #{%(<span class="help" id="#{dom_id(field.path)}-help">#{Escape.html(field.help)}</span>) if field.help}
            #{%(<span class="help" role="alert">#{Escape.html(error)}</span>) if error}
          </div>
        HTML
      end

      def self.required_mark(field) = field.required? ? %(<span class="required-mark" title="required">*</span>) : ""

      # "amount.cents" -> "f-amount-cents".
      def self.dom_id(path) = "f-#{path.to_s.tr(".", "-")}"

      # String form, for controls assembled by hand rather than through `Tag.void`.
      def self.aria(field)
        Tag.attrs(required: field.required?, aria_describedby: field.help ? "#{dom_id(field.path)}-help" : nil)
      end

      # Hash form of `aria`, to splat into `Tag.void`.
      def self.aria_attrs(field)
        { required: field.required?, aria_describedby: field.help ? "#{dom_id(field.path)}-help" : nil }
      end

      # Reads the value held for a dotted path from either a flat or a nested values hash.
      def self.dig(values, path)
        return nil unless values.is_a?(Hash)

        # A sticky re-render hands back raw flat params ({"amount.cents"=>"1050"}); a prefill
        # from a record's state is nested ({amount: {cents: 1050}}). Flat wins when both answer.
        # Test with `key?`, never `||`, so a held `false` is not mistaken for an absent key.
        str = path.to_s
        return values[str] if values.key?(str)

        sym = path.to_sym
        return values[sym] if values.key?(sym)

        str.split(".").reduce(values) do |acc, segment|
          break nil unless acc.is_a?(Hash)

          seg_sym = segment.to_sym
          acc.key?(seg_sym) ? acc[seg_sym] : acc[segment]
        end
      end
    end
  end
end
