require_relative "html"
require_relative "field_shape"
require_relative "../naming"

module Hecks
  module Forms
    # A Field (field_shape.rb) -> the `<div class="field">...</div>` or
    # `<fieldset>...</fieldset>` markup for it. One renderer, called
    # recursively for a group's children, shared by CommandFormRenderer
    # (POST) and QueryFormRenderer (GET) — the same attribute shape asks
    # for the same input either way; only the surrounding `<form>`'s
    # method differs.
    module FieldRenderer
      # Renders one field, and recursively a group's children, as form markup with any held
      # value filled back in.
      #
      # `values` is the hash a sticky re-render (a rejected command,
      # a submitted query) carries back — read with the same dotted path a
      # Field already carries, via `dig`. `reference_options` maps a
      # `:reference` field's own path to `[[id, label], ...]`, built by the
      # caller (it needs a repository; this module stays pure markup).
      #
      # @param field [Forms::Field] the field to render
      # @param values [Hash{String, Symbol => Object}] held values, either flat and keyed by
      #   dotted path or nested by path segment; see `dig`
      # @param errors [Hash{String => String}, nil] message per dotted field path; nil for none
      # @param reference_options [Hash{String => Array<Array>, nil}] `[id, label]` pairs per
      #   `:reference` field path, as `ReferenceOptions.collect` builds them; a nil or empty
      #   entry renders a plain text input
      # @return [String] HTML for the field: a `<fieldset>` for `:group` and `:money`, a
      #   `<div class="field">` otherwise
      def self.render(field, values: {}, errors: nil, reference_options: {})
        case field.kind
        when :group  then group(field, values, errors, reference_options, tag: "fieldset")
        when :money  then group(field, values, errors, reference_options, tag: "fieldset", css: "money")
        when :list   then list(field, values, errors)
        else              leaf(field, values, errors, reference_options)
        end
      end

      # Renders a field's children inside one enclosing element, with the field's label as
      # its `<legend>`.
      #
      # @param field [Forms::Field] a `:group` or `:money` field carrying `children`
      # @param values [Hash{String, Symbol => Object}] held values; see `dig`
      # @param errors [Hash{String => String}, nil] message per dotted field path
      # @param reference_options [Hash{String => Array<Array>, nil}] `[id, label]` pairs per
      #   `:reference` field path
      # @param tag [String] name of the enclosing element, such as `"fieldset"`
      # @param css [String, nil] class attribute for the enclosing element; nil for none
      # @return [String] HTML for the enclosing element and every child
      def self.group(field, values, errors, reference_options, tag:, css: nil)
        inner = field.children.map { |child| render(child, values: values, errors: errors, reference_options: reference_options) }
        <<~HTML
          <#{tag}#{%( class="#{css}") if css}>
            <legend>#{Escape.html(field.label)}#{required_mark(field)}</legend>
            #{inner.join("\n")}
          </#{tag}>
        HTML
      end

      # Renders a `:list` field as one textarea taking an element per line, which is the shape
      # `Params.extract_list` reads back.
      #
      # @param field [Forms::Field] a `:list` field whose first child describes one element
      # @param values [Hash{String, Symbol => Object}] held values; the list's entry may be an
      #   Array, a newline-joined String, or absent
      # @param _errors [Hash{String => String}, nil] ignored; a list shows no per-field message
      # @return [String] HTML for the labelled textarea and its help line
      def self.list(field, values, _errors)
        item = field.children.first
        current = Array(dig(values, field.path)).join("\n")
        <<~HTML
          <div class="field">
            <label for="#{dom_id(field.path)}">#{Escape.html(field.label)}#{required_mark(field)}</label>
            <textarea id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}"
              #{aria(field)} placeholder="one #{Escape.attr(item.label.downcase)} per line">#{Escape.html(current)}</textarea>
            <span class="help" id="#{dom_id(field.path)}-help">One #{Escape.html(item.label.downcase)} per line#{' — each line is one JSON object' unless item.leaf?}.</span>
          </div>
        HTML
      end

      # Renders a single-value field with the control its `kind` calls for, wrapped with its
      # label, help text and error.
      #
      # @param field [Forms::Field] a leaf field
      # @param values [Hash{String, Symbol => Object}] held values; see `dig`
      # @param errors [Hash{String => String}, nil] message per dotted field path
      # @param reference_options [Hash{String => Array<Array>, nil}] `[id, label]` pairs per
      #   `:reference` field path
      # @return [String] HTML for the `<div class="field">` block
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

      # Wraps a rendered control with its label, help text and error message; a `:boolean`
      # gets no label here because `checkbox` renders its own beside the box.
      #
      # @param field [Forms::Field] the field the control belongs to
      # @param body [String] HTML of the control itself
      # @param error [String, nil] message shown as an alert; nil for none
      # @return [String] HTML for the `<div class="field">` block, classed `has-error` when
      #   `error` is given
      def self.wrap(field, body, error)
        <<~HTML
          <div class="field#{' has-error' if error}">
            #{%(<label for="#{dom_id(field.path)}">#{Escape.html(field.label)}#{required_mark(field)}</label>) unless field.kind == :boolean}
            #{body}
            #{%(<span class="help" id="#{dom_id(field.path)}-help">#{Escape.html(field.help)}</span>) if field.help}
            #{%(<span class="help" role="alert">#{Escape.html(error)}</span>) if error}
          </div>
        HTML
      end

      # Renders an `<input>` of the field's `html_type`, falling back to the field's default
      # for a missing value; a whole-cents number also gets a live preview span.
      #
      # @param field [Forms::Field] a leaf field
      # @param value [Object, nil] the held value, rendered with `to_s`; nil shows the default
      # @return [String] HTML for the input, followed by the preview `<span>` when the field
      #   is a `:number` whose help text mentions cents
      def self.input(field, value)
        money = field.kind == :number && field.help.to_s.include?("cents")
        tag = Tag.void("input", id: dom_id(field.path), name: field.path, type: field.html_type,
                        value: value || field.default, step: field.step, pattern: leaf_pattern(field),
                        placeholder: field.default, **aria_attrs(field),
                        **(money ? { data_money_cents: money_preview_target(field) } : {}))
        return tag unless money

        %(#{tag} <span id="#{dom_id(field.path)}-preview" class="mono help" aria-live="polite"></span>)
      end

      # Renders a `<textarea>` holding the value as escaped text; unlike `input`, the field's
      # default is not filled in.
      #
      # @param field [Forms::Field] a `:textarea` field
      # @param value [Object, nil] the held value, rendered with `to_s`; nil renders empty
      # @return [String] HTML for the textarea
      def self.textarea(field, value)
        %(<textarea id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{Escape.html(value)}</textarea>)
      end

      # Renders a checkbox preceded by a hidden `"0"` input of the same name, so an unticked
      # box still submits a value, with the field's label beside it.
      #
      # @param field [Forms::Field] a `:boolean` field
      # @param value [Boolean, String, nil] the held value; `true`, `"true"`, `"on"` and `"1"`
      #   tick the box, and nil falls back to a default of exactly `true`
      # @return [String] HTML for the checkbox row
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

      # Renders one radio button per option, pre-checking the one equal to the held value or,
      # failing that, to the field's default.
      #
      # @param field [Forms::Field] a `:radio` field whose `options` are `[value, label]` pairs
      # @param value [Object, nil] the held value, compared with `to_s`; nil falls back to the
      #   default
      # @return [String] HTML for the `<div role="radiogroup">` block
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

      # Renders a `<select>` over the field's fixed options, with a blank "—" entry first when
      # the field is optional.
      #
      # @param field [Forms::Field] a `:select` field whose `options` are `[value, label]` pairs
      # @param value [Object, nil] the held value, compared with `to_s`; nil falls back to the
      #   default
      # @return [String] HTML for the select
      def self.select(field, value)
        selected = value || field.default
        options = field.options.map do |option_value, option_label|
          %(<option value="#{Escape.attr(option_value)}"#{' selected' if option_value.to_s == selected.to_s}>) \
            "#{Escape.html(option_label)}</option>"
        end
        blank = field.optional? ? %(<option value="">—</option>) : ""
        %(<select id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{blank}#{options.join}</select>)
      end

      # Renders a `<select>` of existing records for a `:reference` field, degrading to a plain
      # text id input when no records are on offer.
      #
      # @param field [Forms::Field] a `:reference` field; its `html_type` is set to `"text"`
      #   in place when the text fallback is taken
      # @param value [Object, nil] the held id, compared with `to_s`; nil preselects the
      #   disabled "choose one…" entry of a required field
      # @param options [Array<Array>, nil] `[id, label]` pairs to offer; nil or empty takes the
      #   text fallback
      # @return [String] HTML for the select, or for the fallback `<input>`
      def self.reference_select(field, value, options)
        return input(field.tap { |f| f.html_type = "text" }, value) unless options && !options.empty?

        rendered = options.map do |id, label|
          %(<option value="#{Escape.attr(id)}"#{' selected' if id.to_s == value.to_s}>#{Escape.html(label)}</option>)
        end
        blank = if field.optional?
                  %(<option value="">—</option>)
                else
                  %(<option value="" disabled#{' selected' unless value}>choose one…</option>)
                end
        %(<select id="#{dom_id(field.path)}" name="#{Escape.attr(field.path)}" #{aria(field)}>#{blank}#{rendered.join}</select>)
      end

      # Renders the asterisk that marks a required field's label or legend.
      #
      # @param field [Forms::Field] the field being labelled
      # @return [String] HTML for the mark, or `""` when the field is optional
      def self.required_mark(field) = field.required? ? %(<span class="required-mark" title="required">*</span>) : ""

      # Derives the element id of a field's control from its dotted path, such as
      # `"f-amount-cents"` for `"amount.cents"`.
      #
      # @param path [String, Symbol] the field's dotted path
      # @return [String] the id, `"f-"` followed by the path with dots turned to hyphens
      def self.dom_id(path) = "f-#{path.to_s.tr('.', '-')}"

      # Picks the `pattern` attribute an input carries, withholding it from a `:reference`
      # field, whose input takes a record id rather than the attribute's own value.
      #
      # @param field [Forms::Field] a leaf field
      # @return [String, nil] the regex source the attribute declares as `pattern:`; nil for a
      #   `:reference` field or when none is declared
      def self.leaf_pattern(field) = field.kind == :reference ? nil : field.pattern

      # Names the preview span a whole-cents input's `data-money-cents` attribute points at.
      #
      # @param field [Forms::Field] the cents field
      # @return [String] a CSS id selector, such as `"#f-amount-cents-preview"`
      def self.money_preview_target(field) = "##{dom_id(field.path)}-preview"

      # Renders the `required` and `aria-describedby` attributes of a control as an
      # attribute string, for the controls assembled by hand rather than through `Tag.void`.
      #
      # @param field [Forms::Field] the field the control belongs to
      # @return [String] the rendered attributes, or `""` when the field is optional and has
      #   no help text
      def self.aria(field)
        Tag.attrs(required: field.required?, aria_describedby: field.help ? "#{dom_id(field.path)}-help" : nil)
      end

      # Builds the `required` and `aria-describedby` attributes of a control as a Hash, to
      # splat into `Tag.void`.
      #
      # @param field [Forms::Field] the field the control belongs to
      # @return [Hash{Symbol => Boolean, String, nil}] `:required` and `:aria_describedby`;
      #   the latter is the help span's element id, or nil when the field has no help text
      def self.aria_attrs(field)
        { required: field.required?, aria_describedby: field.help ? "#{dom_id(field.path)}-help" : nil }
      end

      # Reads the value held for a dotted field path out of either spelling a form's values
      # arrive in, flat or nested, without losing a stored `false`.
      #
      # `values` is a nested hash; `path` a dotted string using the same
      # segment spelling the hash keys are built from (`Params.nest` in
      # params.rb) — symbols one level down from a group, strings at the
      # flat top when a sticky POST re-render hands raw params back untouched.
      #
      # @param values [Hash{String, Symbol => Object}, Object] held values; anything that is
      #   not a Hash, nil included, reads as nil
      # @param path [String, Symbol] the field's dotted path, such as `"amount.cents"`
      # @return [Object, nil] the held value exactly as stored (a raw form String, or a typed
      #   value from a record's state); nil when no key on the path answers
      def self.dig(values, path)
        return nil unless values.is_a?(Hash)

        # A sticky re-render after a refused submission hands back the raw
        # flat params (`{"amount.cents"=>"1050"}` — the same shape the form
        # posted, string values and all, dotted key intact) ; a prefill from
        # an existing record's own state hands back a nested hash instead
        # (`{amount: {cents: 1050}}`). Flat wins when both would answer,
        # since only the raw form is ever what the caller actually typed.
        # `key?` decides which spelling answers, at every step below —
        # never `||`, which would treat a genuinely-held `false` the
        # same as an absent key and fall through to `nil`.
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
