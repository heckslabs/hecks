require "json"
require "uri"
require_relative "field_renderer"

module Hecks
  module Forms
    # The two directions between a flat, dotted, ALL-STRINGS web payload
    # (`{"amount.cents"=>"1050", "amount.currency"=>"USD"}`, whether it came
    # off a POST form body or a GET query string — Rack hands back the same
    # flat shape for both as long as nothing uses `[]` bracket names) and the
    # nested, typed hash `Dispatcher#dispatch`/`#query` actually take
    # (`{amount: {cents: 1050, currency: "USD"}}`).
    #
    # `extract` NEEDS the Field tree, not just the raw params — a numeric
    # leaf's own runtime check (`Value::Coercion#check_numeric_fields`)
    # requires an actual `Integer`/`Float`, not a String that merely looks
    # like one (`given.is_a?(expected)`, no coercion attempted there); a web
    # form can only ever hand back strings, so the cast has to happen here,
    # once, using the SAME shape `FieldShape` already resolved for
    # rendering the input in the first place — one reading of the IR, not
    # two that could disagree.
    module Params
      # Every LEAF field carries its own full dotted path regardless of how
      # deep `FieldShape` nested it to get there — a single-attribute value
      # object unwraps to a leaf sitting at the TOP of the fields array with
      # a two-segment path (`"reference.value"`), the exact same shape a
      # `:group`'s own child carries. So this collects every leaf as
      # (full path -> value) FIRST, and nests by the path's OWN segments
      # last — one nesting rule, blind to how a field arrived at its path.
      def self.extract(fields, raw)
        pairs = {}
        fields.each { |field| collect(field, raw, pairs) }
        nest(pairs)
      end

      def self.collect(field, raw, pairs)
        case field.kind
        when :group, :money then field.children.each { |child| collect(child, raw, pairs) }
        when :list then (value = extract_list(field, raw)) == SKIP || pairs[field.path] = value
        else (value = extract_leaf(field, raw)) == SKIP || pairs[field.path] = value
        end
      end

      # A path-prefix collision: one field named (say) "price" alongside
      # another named "price.cents" implies "price" is BOTH a scalar leaf
      # and the parent of a nested group — the two can never coexist in
      # the same result hash. Depending on which pair `each_with_object`
      # reaches first, the naive walk below used to fail in one of two
      # ways: a scalar planted first left `acc[segment] ||= {}` seeing a
      # truthy non-Hash and reusing IT as `node`, so the next `node[leaf] =
      # value` blew up with a raw `TypeError` from calling `String#[]=`
      # with a Symbol key; a scalar planted AFTER the nested group instead
      # sailed through `node[leaf] = value` and silently clobbered the
      # entire nested hash with the scalar, losing every sibling under it
      # with no error at all. Both directions are checked explicitly here
      # so either order raises the SAME clear `ArgumentError` instead of a
      # confusing crash or silent data loss — this is the family of error
      # every command/query submission path in app.rb already rescues into
      # a 422 (`ArgumentError` sits right alongside the domain refusals in
      # every one of those rescue clauses).
      def self.nest(pairs)
        pairs.each_with_object({}) do |(path, value), result|
          segments = path.to_s.split(".").map(&:to_sym)
          leaf = segments.pop
          node = segments.reduce(result) do |acc, segment|
            existing = acc[segment]
            raise nesting_collision(path) if existing && !existing.is_a?(Hash)

            acc[segment] ||= {}
          end
          raise nesting_collision(path) if node[leaf].is_a?(Hash)

          node[leaf] = value
        end
      end

      def self.nesting_collision(path)
        ArgumentError.new("#{path.inspect} conflicts with another field at the same path — " \
                          "one names it as a plain value and another as a nested group")
      end

      SKIP = Object.new.freeze
      private_constant :SKIP

      # One line of the textarea per element. A line that itself needs
      # several fields (a multi-attribute value object as a list element)
      # is read as JSON on that one line — the honest fallback documented in
      # docs/command-form-and-query-form-bluebook.md rather than a second
      # widget this prototype doesn't build yet.
      def self.extract_list(field, raw)
        text = raw[field.path]
        return SKIP if text.nil? || text.strip.empty?

        item = field.children.first
        text.each_line.map(&:strip).reject(&:empty?).map do |line|
          item.leaf? ? cast_scalar(item, line) : JSON.parse(line, symbolize_names: true)
        end
      end

      def self.extract_leaf(field, raw)
        return checkbox(raw[field.path]) if field.kind == :boolean

        text = raw[field.path]
        return SKIP if (text.nil? || text.empty?) && field.optional?

        cast_scalar(field, text)
      end

      def self.checkbox(raw_value)
        %w[on 1 true].include?(raw_value.to_s.downcase)
      end

      def self.cast_scalar(field, text)
        case field.kind
        when :number then field.step == "1" ? Integer(text) : Float(text)
        else text
        end
      end

      # The other direction — a nested value hash back to the flat dotted
      # pairs a GET link's query string carries, so a query view's
      # "shareable link" and its filter FORM stay two renderings of the
      # SAME data rather than two formats that can drift. Reads with
      # `FieldRenderer.dig` — the identical full-path lookup a re-rendered
      # input's own value comes from — for the same reason `extract` above
      # nests by full path rather than by tree shape.
      def self.flatten(fields, values, into: {})
        fields.each do |field|
          case field.kind
          when :group, :money then flatten(field.children, values, into: into)
          when :list then into[field.path] = Array(FieldRenderer.dig(values, field.path)).join("\n")
          else
            value = FieldRenderer.dig(values, field.path)
            into[field.path] = value.to_s unless value.nil?
          end
        end
        into
      end

      # Every leaf/list path a field tree carries, independent of any
      # values — what `command_form_renderer.rb`'s inspect panel wants
      # ("which fields does this command take"), where `flatten` above wants
      # "what does THIS submission look like" and returns nothing for a
      # field nothing was entered for.
      def self.paths(fields, into: [])
        fields.each do |field|
          case field.kind
          when :group, :money then paths(field.children, into: into)
          else into << field.path
          end
        end
        into
      end

      def self.to_query_string(fields, values)
        pairs = flatten(fields, values)
        pairs.map { |key, value| "#{URI.encode_www_form_component(key)}=#{URI.encode_www_form_component(value)}" }.join("&")
      end
    end
  end
end
