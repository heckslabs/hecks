require_relative "html"
require_relative "../naming"

module Hecks
  module Forms
    module FieldRenderer
      # The single controls a leaf field renders as: input, textarea, checkbox, radio group,
      # select and reference picker.
      module Controls
        # @return [String] an `<input>`, with a live preview beside a money amount in cents
        def self.input(field, value)
          money = field.kind == :number && field.help.to_s.include?("cents")
          tag = Tag.void("input", **input_attrs(field, value), **(money ? { data_money_cents: preview_target(field) } : {}))
          return tag unless money

          %(#{tag} <span id="#{FieldRenderer.dom_id(field.path)}-preview" class="mono help" aria-live="polite"></span>)
        end

        def self.input_attrs(field, value)
          { id: FieldRenderer.dom_id(field.path), name: field.path, type: field.html_type,
            value: value || field.default, step: field.step, pattern: leaf_pattern(field),
            placeholder: field.default }.merge(FieldRenderer.aria_attrs(field))
        end

        # A :reference input takes a record id, so the attribute's own pattern must not apply.
        def self.leaf_pattern(field) = field.kind == :reference ? nil : field.pattern

        def self.preview_target(field) = "##{FieldRenderer.dom_id(field.path)}-preview"

        # @return [String] a `<textarea>` holding the value
        def self.textarea(field, value)
          id = FieldRenderer.dom_id(field.path)
          %(<textarea id="#{id}" name="#{Escape.attr(field.path)}" #{FieldRenderer.aria(field)}>#{Escape.html(value)}</textarea>)
        end

        # The hidden "0" input makes an unticked box still submit a value.
        def self.checkbox(field, value)
          checked = value.nil? ? field.default == true : [true, "true", "on", "1"].include?(value)
          <<~HTML
            <div class="checkbox-row">
              <input type="hidden" name="#{Escape.attr(field.path)}" value="0">
              #{Tag.void("input", id: FieldRenderer.dom_id(field.path), name: field.path, type: "checkbox", value: "1", checked: checked)}
              <label for="#{FieldRenderer.dom_id(field.path)}">#{Escape.html(field.label)}</label>
            </div>
          HTML
        end

        def self.radio_group(field, value)
          selected = value || field.default
          options = field.options.map { |option_value, option_label| radio(field, option_value, option_label, selected) }
          %(<div class="radio-group" role="radiogroup">#{options.join}</div>)
        end

        def self.radio(field, option_value, option_label, selected)
          checked = option_value.to_s == selected.to_s
          id = "#{FieldRenderer.dom_id(field.path)}-#{Naming.snake(option_value)}"
          <<~HTML
            <label>#{Tag.void("input", id: id, type: "radio", name: field.path, value: option_value, checked: checked)} #{Escape.html(option_label)}</label>
          HTML
        end

        def self.select(field, value)
          selected = value || field.default
          options = field.options.map do |option_value, option_label|
            %(<option value="#{Escape.attr(option_value)}"#{" selected" if option_value.to_s == selected.to_s}>) \
              "#{Escape.html(option_label)}</option>"
          end
          blank = field.optional? ? %(<option value="">—</option>) : ""
          select_tag(field, "#{blank}#{options.join}")
        end

        # Falls back to a plain text id input when no records are on offer.
        def self.reference_select(field, value, options)
          return input(field.tap { |f| f.html_type = "text" }, value) unless options && !options.empty?

          rendered = options.map do |id, label|
            %(<option value="#{Escape.attr(id)}"#{" selected" if id.to_s == value.to_s}>#{Escape.html(label)}</option>)
          end
          select_tag(field, "#{reference_blank(field, value)}#{rendered.join}")
        end

        def self.reference_blank(field, value)
          return %(<option value="">—</option>) if field.optional?

          %(<option value="" disabled#{" selected" unless value}>choose one…</option>)
        end

        def self.select_tag(field, options_html)
          id = FieldRenderer.dom_id(field.path)
          %(<select id="#{id}" name="#{Escape.attr(field.path)}" #{FieldRenderer.aria(field)}>#{options_html}</select>)
        end
      end
    end
  end
end
