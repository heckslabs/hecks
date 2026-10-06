require_relative "html"
require_relative "field_shape"
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
        case field.kind
        when :group  then group(field, values, errors, reference_options, tag: "fieldset")
        when :money  then group(field, values, errors, reference_options, tag: "fieldset", css: "money")
        when :list   then list(field, values, errors)
        else              leaf(field, values, errors, reference_options)
        end
      end

      def self.group(field, values, errors, reference_options, tag:, css: nil)
        inner = field.children.map { |child| render(child, values: values, errors: errors, reference_options: reference_options) }
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
        current = Array(dig(values, field.path)).join("\n")
        <<~HTML
          <div class="field">
            <label for="#{dom_id(field.path)}">#{Escape.html(field.label)}#{required_mark(field)}</label>
            <textarea id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}"
              #{aria(field)} placeholder="one #{Escape.attr(item.label.downcase)} per line">#{Escape.html(current)}</textarea>
            <span class="help" id="#{dom_id(field.path)}-help">One #{Escape.html(item.label.downcase)} per line#{" — each line is one JSON object" unless item.leaf?}.</span>
          </div>
        HTML
      end

      def self.leaf(field, values, errors, reference_options)
        value = dig(values, field.path)
        error = errors && errors[field.path]
        body = case field.kind
               when :boolean  then checkbox(field, value)
               when :radio    then radio_group(field, value)
               when :select   then select(field, value)
               when :textarea then textarea(field, value)
               when :reference then reference_select(field, value, reference_options[field.path])
               else input(field, value)
               end
        wrap(field, body, error)
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

      def self.input(field, value)
        money = field.kind == :number && field.help.to_s.include?("cents")
        tag = Tag.void("input", id: dom_id(field.path), name: field.path, type: field.html_type,
                        value: value || field.default, step: field.step, pattern: leaf_pattern(field),
                        placeholder: field.default, **aria_attrs(field),
                        **(money ? { data_money_cents: money_preview_target(field) } : {}))
        return tag unless money

        %(#{tag} <span id="#{dom_id(field.path)}-preview" class="mono help" aria-live="polite"></span>)
      end

      def self.textarea(field, value)
        %(<textarea id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{Escape.html(value)}</textarea>)
      end

      # The hidden "0" input makes an unticked box still submit a value.
      def self.checkbox(field, value)
        checked = value.nil? ? field.default == true : [true, "true", "on", "1"].include?(value)
        <<~HTML
          <div class="checkbox-row">
            <input type="hidden" name="#{Escape.attr(field.path)}" value="0">
            #{Tag.void("input", id: dom_id(field.path), name: field.path, type: "checkbox", value: "1", checked: checked)}
            <label for="#{dom_id(field.path)}">#{Escape.html(field.label)}</label>
          </div>
        HTML
      end

      def self.radio_group(field, value)
        selected = value || field.default
        options = field.options.map do |option_value, option_label|
          checked = option_value.to_s == selected.to_s
          id = "#{dom_id(field.path)}-#{Naming.snake(option_value)}"
          <<~HTML
            <label>#{Tag.void("input", id: id, type: "radio", name: field.path, value: option_value, checked: checked)} #{Escape.html(option_label)}</label>
          HTML
        end
        %(<div class="radio-group" role="radiogroup">#{options.join}</div>)
      end

      def self.select(field, value)
        selected = value || field.default
        options = field.options.map do |option_value, option_label|
          %(<option value="#{Escape.attr(option_value)}"#{" selected" if option_value.to_s == selected.to_s}>) \
            "#{Escape.html(option_label)}</option>"
        end
        blank = field.optional? ? %(<option value="">—</option>) : ""
        %(<select id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{blank}#{options.join}</select>)
      end

      # Falls back to a plain text id input when no records are on offer.
      def self.reference_select(field, value, options)
        return input(field.tap { |f| f.html_type = "text" }, value) unless options && !options.empty?

        rendered = options.map do |id, label|
          %(<option value="#{Escape.attr(id)}"#{" selected" if id.to_s == value.to_s}>#{Escape.html(label)}</option>)
        end
        blank = if field.optional?
                  %(<option value="">—</option>)
                else
                  %(<option value="" disabled#{" selected" unless value}>choose one…</option>)
                end
        %(<select id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{blank}#{rendered.join}</select>)
      end

      def self.required_mark(field) = field.required? ? %(<span class="required-mark" title="required">*</span>) : ""

      # "amount.cents" -> "f-amount-cents".
      def self.dom_id(path) = "f-#{path.to_s.tr(".", "-")}"

      # A :reference input takes a record id, so the attribute's own pattern must not apply.
      def self.leaf_pattern(field) = field.kind == :reference ? nil : field.pattern

      def self.money_preview_target(field) = "##{dom_id(field.path)}-preview"

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
