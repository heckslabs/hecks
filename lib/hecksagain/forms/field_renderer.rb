require_relative "html"
require_relative "field_shape"
require_relative "../naming"

module Hecksagain
  module Forms
    # A Field (field_shape.rb) -> the `<div class="field">...</div>` or
    # `<fieldset>...</fieldset>` markup for it. One renderer, called
    # recursively for a group's children, shared by CommandFormRenderer
    # (POST) and QueryFormRenderer (GET) — the same attribute shape asks
    # for the same input either way; only the surrounding `<form>`'s
    # method differs.
    module FieldRenderer
      # `values` is the nested hash a sticky re-render (a rejected command,
      # a submitted query) carries back — read with the SAME dotted path a
      # Field already carries, via `dig`. `reference_options` maps a
      # `:reference` field's own path to `[[id, label], ...]`, built by the
      # caller (it needs a repository; this module stays pure markup).
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
          <#{tag}#{css ? %( class="#{css}") : ""}>
            <legend>#{Escape.html(field.label)}#{required_mark(field)}</legend>
            #{inner.join("\n")}
          </#{tag}>
        HTML
      end

      def self.list(field, values, _errors)
        item = field.children.first
        current = Array(dig(values, field.path)).join("\n")
        <<~HTML
          <div class="field">
            <label for="#{dom_id(field.path)}">#{Escape.html(field.label)}#{required_mark(field)}</label>
            <textarea id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}"
              #{aria(field)} placeholder="one #{Escape.attr(item.label.downcase)} per line">#{Escape.html(current)}</textarea>
            <span class="help" id="#{dom_id(field.path)}-help">One #{Escape.html(item.label.downcase)} per line#{item.leaf? ? '' : ' — each line is one JSON object'}.</span>
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

      def self.wrap(field, body, error)
        <<~HTML
          <div class="field#{error ? ' has-error' : ''}">
            #{field.kind == :boolean ? '' : %(<label for="#{dom_id(field.path)}">#{Escape.html(field.label)}#{required_mark(field)}</label>)}
            #{body}
            #{field.help ? %(<span class="help" id="#{dom_id(field.path)}-help">#{Escape.html(field.help)}</span>) : ''}
            #{error ? %(<span class="help" role="alert">#{Escape.html(error)}</span>) : ''}
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

      def self.checkbox(field, value)
        checked = value.nil? ? field.default == true : [true, "true", "on", "1"].include?(value)
        <<~HTML
          <div class="checkbox-row">
            <input type="hidden" name="#{Escape.attr(field.path)}" value="0">
            #{Tag.void('input', id: dom_id(field.path), name: field.path, type: 'checkbox', value: '1', checked: checked)}
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
            <label>#{Tag.void('input', id: id, type: 'radio', name: field.path, value: option_value, checked: checked)} #{Escape.html(option_label)}</label>
          HTML
        end
        %(<div class="radio-group" role="radiogroup">#{options.join}</div>)
      end

      def self.select(field, value)
        selected = value || field.default
        options = field.options.map do |option_value, option_label|
          %(<option value="#{Escape.attr(option_value)}"#{option_value.to_s == selected.to_s ? ' selected' : ''}>#{Escape.html(option_label)}</option>)
        end
        blank = field.optional? ? %(<option value="">—</option>) : ""
        %(<select id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{blank}#{options.join}</select>)
      end

      def self.reference_select(field, value, options)
        return input(field.tap { |f| f.html_type = "text" }, value) unless options && !options.empty?

        rendered = options.map do |id, label|
          %(<option value="#{Escape.attr(id)}"#{id.to_s == value.to_s ? ' selected' : ''}>#{Escape.html(label)}</option>)
        end
        blank = field.optional? ? %(<option value="">—</option>) : %(<option value="" disabled#{value ? '' : ' selected'}>choose one…</option>)
        %(<select id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{blank}#{rendered.join}</select>)
      end

      def self.required_mark(field) = field.required? ? %(<span class="required-mark" title="required">*</span>) : ""
      def self.dom_id(path) = "f-#{path.to_s.tr('.', '-')}"
      def self.leaf_pattern(field) = field.kind == :reference ? nil : field.pattern
      def self.money_preview_target(field) = "##{dom_id(field.path)}-preview"

      def self.aria(field)
        Tag.attrs(required: field.required?, aria_describedby: field.help ? "#{dom_id(field.path)}-help" : nil)
      end

      def self.aria_attrs(field)
        { required: field.required?, aria_describedby: field.help ? "#{dom_id(field.path)}-help" : nil }
      end

      # `values` is a nested hash; `path` a dotted string using the SAME
      # segment spelling the hash keys are built from (`leaf_key` in
      # params.rb) — symbols one level down from a group, strings at the
      # flat top when a sticky POST re-render hands raw params back untouched.
      def self.dig(values, path)
        return nil unless values.is_a?(Hash)

        # A sticky re-render after a refused submission hands back the RAW
        # flat params (`{"amount.cents"=>"1050"}` — the same shape the form
        # posted, string values and all, dotted key intact) ; a prefill from
        # an existing record's own state hands back a NESTED hash instead
        # (`{amount: {cents: 1050}}`). Flat wins when both would answer,
        # since only the raw form is ever what the caller actually typed.
        flat = values[path.to_s] || values[path.to_sym]
        return flat unless flat.nil?

        path.to_s.split(".").reduce(values) do |acc, segment|
          break nil unless acc.is_a?(Hash)

          acc[segment.to_sym] || acc[segment]
        end
      end
    end
  end
end
