require "json"
require "uri"
require_relative "field_renderer"

module Hecks
  module Forms
    # The two directions between a flat, dotted, all-strings web payload
    # (`{"amount.cents"=>"1050", "amount.currency"=>"USD"}`, whether it came
    # off a POST form body or a GET query string — Rack hands back the same
    # flat shape for both as long as nothing uses `[]` bracket names) and the
    # nested, typed hash `Dispatcher#dispatch`/`#query` actually take
    # (`{amount: {cents: 1050, currency: "USD"}}`).
    #
    # `extract` needs the Field tree, not just the raw params — a numeric
    # leaf's own runtime check (`Value::Coercion#check_numeric_fields`)
    # requires an actual `Integer`/`Float`, not a String that merely looks
    # like one (`given.is_a?(expected)`, no coercion attempted there); a web
    # form can only ever hand back strings, so the cast has to happen here,
    # once, using the same shape `FieldShape` already resolved for
    # rendering the input in the first place — one reading of the IR, not
    # two that could disagree.
    module Params
      # Casts a flat, all-strings web payload into the nested, typed arguments a command or
      # query takes, guided by the field tree the form was rendered from.
      #
      # Every leaf field carries its own full dotted path regardless of how
      # deep `FieldShape` nested it to get there — a single-attribute value
      # object unwraps to a leaf sitting at the top of the fields array with
      # a two-segment path (`"reference.value"`), the exact same shape a
      # `:group`'s own child carries. So this collects every leaf as
      # (full path -> value) first, and nests by the path's own segments
      # last — one nesting rule, blind to how a field arrived at its path.
      #
      # @param fields [Array<Forms::Field>] the resolved field tree the payload was posted
      #   against
      # @param raw [Hash{String => String}] the flat web payload, keyed by dotted field path
      # @return [Hash{Symbol => Object}] nested, typed arguments keyed by path segment, ready
      #   to splat into a dispatch; a blank optional field is left out
      # @raise [ArgumentError] if a number field's text is not numeric, or two fields collide
      #   at one path (see `nest`)
      # @raise [TypeError] if a required number field is missing from `raw`
      # @raise [JSON::ParserError] if a line of a list-of-value-objects field is not JSON
      def self.extract(fields, raw)
        pairs = {}
        fields.each { |field| collect(field, raw, pairs) }
        nest(pairs)
      end

      # Gathers one field's typed value, and recursively its children's, into `pairs` under
      # each leaf's full dotted path; a blank optional leaf adds nothing.
      #
      # @param field [Forms::Field] the field to read
      # @param raw [Hash{String => String}] the flat web payload, keyed by dotted field path
      # @param pairs [Hash{String => Object}] accumulator of typed values by dotted path,
      #   added to in place
      # @return [void]
      # @raise [ArgumentError] if a number field's text is not numeric
      # @raise [TypeError] if a required number field is missing from `raw`
      # @raise [JSON::ParserError] if a line of a list-of-value-objects field is not JSON
      def self.collect(field, raw, pairs)
        case field.kind
        when :group, :money then field.children.each { |child| collect(child, raw, pairs) }
        when :list then (value = extract_list(field, raw)) == SKIP || pairs[field.path] = value
        else (value = extract_leaf(field, raw)) == SKIP || pairs[field.path] = value
        end
      end

      # Nests values keyed by dotted path into a Hash keyed by path segment, refusing two
      # paths that cannot share one result.
      #
      # A path-prefix collision: one field named (say) "price" alongside
      # another named "price.cents" implies "price" is both a scalar leaf
      # and the parent of a nested group — the two can never coexist in
      # the same result hash. Depending on which pair `each_with_object`
      # reaches first, an unguarded walk fails in one of two ways: a scalar
      # planted first leaves `acc[segment] ||= {}` seeing a truthy non-Hash
      # and reusing it as `node`, so the next `node[leaf] = value` blows up
      # with a raw `TypeError` from calling `String#[]=` with a Symbol key;
      # a scalar planted after the nested group instead sails through
      # `node[leaf] = value` and silently clobbers the entire nested hash
      # with the scalar, losing every sibling under it with no error at
      # all. Both directions are checked explicitly here so either order
      # raises the same clear `ArgumentError` instead of a confusing crash
      # or silent data loss — this is the family of error every
      # command/query submission path in app.rb already rescues into a 422
      # (`ArgumentError` sits right alongside the domain refusals in every
      # one of those rescue clauses).
      #
      # @param pairs [Hash{String => Object}] values keyed by dotted path, such as
      #   `{"amount.cents" => 1050}`
      # @return [Hash{Symbol => Object}] the nested result, such as `{amount: {cents: 1050}}`
      # @raise [ArgumentError] if one path names a plain value where another names a nested
      #   group, in either order
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

      # Builds, without raising, the error `nest` raises for a path-prefix collision.
      #
      # @param path [String] the dotted path at which the collision was found
      # @return [ArgumentError] an error whose message names the conflicting path
      def self.nesting_collision(path)
        ArgumentError.new("#{path.inspect} conflicts with another field at the same path — " \
                          "one names it as a plain value and another as a nested group")
      end

      SKIP = Object.new.freeze
      private_constant :SKIP

      # Reads a `:list` field's textarea into an Array, one element per non-blank line.
      #
      # One line of the textarea per element. A line that itself needs
      # several fields (a multi-attribute value object as a list element)
      # is read as JSON on that one line — the honest fallback documented in
      # docs/command-form-and-query-form-bluebook.md rather than a second
      # widget this prototype doesn't build yet.
      #
      # @param field [Forms::Field] a `:list` field whose first child describes one element
      # @param raw [Hash{String => String}] the flat web payload, keyed by dotted field path
      # @return [Array<Object>, Object] the elements — cast scalars for a leaf element,
      #   symbol-keyed parsed JSON otherwise — or the private `SKIP` sentinel when the field
      #   is absent or blank
      # @raise [ArgumentError] if a number element's line is not numeric
      # @raise [JSON::ParserError] if a non-leaf element's line is not JSON
      def self.extract_list(field, raw)
        text = raw[field.path]
        return SKIP if text.nil? || text.strip.empty?

        item = field.children.first
        text.each_line.map(&:strip).reject(&:empty?).map do |line|
          item.leaf? ? cast_scalar(item, line) : JSON.parse(line, symbolize_names: true)
        end
      end

      # Reads one leaf field's typed value out of the payload; a boolean always answers, since
      # an unticked checkbox is itself a value.
      #
      # @param field [Forms::Field] a leaf field
      # @param raw [Hash{String => String}] the flat web payload, keyed by dotted field path
      # @return [Boolean, Integer, Float, String, nil, Object] the cast value; nil when a
      #   required non-number field is missing; the private `SKIP` sentinel when an optional
      #   field is absent or empty
      # @raise [ArgumentError] if a number field's text is not numeric
      # @raise [TypeError] if a required number field is missing from `raw`
      def self.extract_leaf(field, raw)
        return checkbox(raw[field.path]) if field.kind == :boolean

        text = raw[field.path]
        return SKIP if (text.nil? || text.empty?) && field.optional?

        cast_scalar(field, text)
      end

      # Reads a submitted checkbox value as a Boolean.
      #
      # @param raw_value [String, nil] the submitted text; nil when the field was not posted
      # @return [Boolean] true for `"on"`, `"1"` or `"true"` in any letter case, false for
      #   anything else
      def self.checkbox(raw_value)
        %w[on 1 true].include?(raw_value.to_s.downcase)
      end

      # Casts a leaf's submitted text to the Ruby type the runtime's numeric check requires,
      # which accepts an actual `Integer` or `Float` and never a numeric-looking String.
      #
      # @param field [Forms::Field] the leaf the text was submitted for
      # @param text [String, nil] the submitted text
      # @return [Integer, Float, String, nil] an Integer for a `:number` field with `step`
      #   `"1"`, a Float for any other `:number` field, and `text` itself for every other kind
      # @raise [ArgumentError] if a number field's text is not numeric
      # @raise [TypeError] if a number field's text is nil
      def self.cast_scalar(field, text)
        case field.kind
        when :number then field.step == "1" ? Integer(text) : Float(text)
        else text
        end
      end

      # Flattens held values back into the dotted-path, all-strings pairs a query string
      # carries — the reverse of `extract`.
      #
      # The other direction — a nested value hash back to the flat dotted
      # pairs a GET link's query string carries, so a query view's
      # "shareable link" and its filter form stay two renderings of the
      # same data rather than two formats that can drift. Reads with
      # `FieldRenderer.dig` — the identical full-path lookup a re-rendered
      # input's own value comes from — for the same reason `extract` above
      # nests by full path rather than by tree shape.
      #
      # @param fields [Array<Forms::Field>] the field tree naming which paths to read
      # @param values [Hash{String, Symbol => Object}] held values, flat or nested; see
      #   `FieldRenderer.dig`
      # @param into [Hash{String => String}] accumulator the pairs are added to in place
      # @return [Hash{String => String}] `into`, holding one pair per leaf with a non-nil value
      #   and one per list (its elements newline-joined, `""` when it holds nothing)
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

      # Lists every dotted path a field tree submits under, whether or not anything was
      # entered for it.
      #
      # Every leaf/list path a field tree carries, independent of any
      # values — what `command_form_renderer.rb`'s inspect panel wants
      # ("which fields does this command take"), where `flatten` above wants
      # "what does this one submission look like" and returns nothing for a
      # field nothing was entered for.
      #
      # @param fields [Array<Forms::Field>] the field tree to walk
      # @param into [Array<String>] accumulator the paths are appended to in place
      # @return [Array<String>] `into`, holding each leaf and list path in render order;
      #   `:group` and `:money` fields contribute their children's paths, not their own
      def self.paths(fields, into: [])
        fields.each do |field|
          case field.kind
          when :group, :money then paths(field.children, into: into)
          else into << field.path
          end
        end
        into
      end

      # Renders held values as a URL query string, percent-encoding each flattened path and
      # value.
      #
      # @param fields [Array<Forms::Field>] the field tree naming which paths to read
      # @param values [Hash{String, Symbol => Object}] held values, flat or nested; see
      #   `FieldRenderer.dig`
      # @return [String] `key=value` pairs joined with `&`, without a leading `?`; `""` when
      #   `flatten` yields no pairs
      def self.to_query_string(fields, values)
        pairs = flatten(fields, values)
        pairs.map { |key, value| "#{URI.encode_www_form_component(key)}=#{URI.encode_www_form_component(value)}" }.join("&")
      end
    end
  end
end
