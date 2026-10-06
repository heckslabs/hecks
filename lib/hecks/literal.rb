module Hecks
  # A mutation source that reads the record's own state: `append: { knights: state(:knights) }`.
  # A bare Symbol in a mutation source names a command argument, so this is the only way to say it.
  StateRef = Struct.new(:name) do
    def to_s = "state(:#{name})"
  end

  # The one wire spelling for a Ruby literal captured from a bluebook: a symbol wears its
  # colon, a string its quotes, a hash `{key: value}`, a list brackets; the rest are bare.
  # Stated here, not left to `inspect`, whose Hash rendering differs between Ruby 3.3 and 3.4.
  module Literal
    module_function

    # Turns a Ruby value into its self-describing wire spelling.
    #
    # @param value [Object] value to render: nil, Symbol, String, StateRef, true,
    #   false, Integer, Float, Hash, or Array (recursively)
    # @return [String] the self-describing spelling `read` can parse back
    # @raise [ArgumentError] if `value` is a type with no pinned literal spelling
    def render(value)
      case value
      when nil    then "nil"
      when Symbol then ":#{value}"
      when String then quote(value)
      when StateRef, true, false, Integer, Float then value.to_s
      when Hash   then "{#{value.map { |key, held| "#{key}: #{render(held)}" }.join(", ")}}"
      when Array  then "[#{value.map { |held| render(held) }.join(", ")}]"
      else
        raise ArgumentError, "#{value.class} has no pinned literal spelling — teach Literal.render one " \
                             "rather than letting #to_s decide it"
      end
    end

    # Parses a wire spelling back into a Ruby value; the exact inverse of `render`.
    # A bare word stays a String, since some fields are stored as plain text, never rendered.
    #
    # @param text [String, #to_s] wire spelling produced by `render`, or a bare word
    # @return [Object] nil, true, false, Integer, Float, Symbol, StateRef, String,
    #   Hash, or Array — or `text` itself, stripped, when it matches no known spelling
    # rubocop:disable-next Metrics/CyclomaticComplexity
    # rubocop:disable-next Metrics/PerceivedComplexity
    def read(text)
      raw = text.to_s.strip
      return nil if raw.empty? || raw == "nil"
      return true if raw == "true"
      return false if raw == "false"
      return raw.to_i if raw.match?(/\A-?\d+\z/)
      return raw.to_f if raw.match?(/\A-?\d+\.\d+\z/)
      return raw[1..].to_sym if raw.start_with?(":")
      return StateRef.new(raw[7..-2].to_sym) if raw.match?(/\Astate\(:[A-Za-z_][A-Za-z0-9_]*\)\z/)
      return unquote(raw) if quoted?(raw)
      return read_hash(raw) if raw.start_with?("{") && raw.end_with?("}")
      return read_array(raw) if raw.start_with?("[") && raw.end_with?("]")

      raw
    end

    ESCAPED = { '"' => '\\"', "\\" => "\\\\" }.freeze

    # Wraps `text` in double quotes, escaping embedded quotes and backslashes.
    #
    # @param text [String] raw text to quote
    # @return [String] the quoted, escaped spelling
    def quote(text) = "\"#{text.gsub(/["\\]/) { |char| ESCAPED[char] }}\""

    # Tells whether `raw` is a double-quoted literal.
    #
    # @param raw [String] wire text to check
    # @return [Boolean]
    def quoted?(raw) = raw.length >= 2 && raw.start_with?('"') && raw.end_with?('"')

    # Strips the surrounding quotes from a quoted literal and unescapes it.
    #
    # @param raw [String] a quoted literal, as `quoted?` would confirm
    # @return [String] the unescaped text inside the quotes
    def unquote(raw) = raw[1..-2].gsub(/\\(.)/) { ::Regexp.last_match(1) }

    # Parses a `{key: value, ...}` wire literal.
    #
    # @param raw [String] text starting with `{` and ending with `}`
    # @return [Hash{Symbol => Object}] the parsed hash, values read recursively via `read`
    def read_hash(raw)
      split_items(raw[1..-2]).to_h do |item|
        key, _, held = item.partition(":")
        [key.strip.to_sym, read(held)]
      end
    end

    # Parses a `[value, ...]` wire literal.
    #
    # @param raw [String] text starting with `[` and ending with `]`
    # @return [Array<Object>] the parsed values, each read recursively via `read`
    def read_array(raw) = split_items(raw[1..-2]).map { |item| read(item) }

    # Splits on separator commas only, never one inside a quoted string or nested brace/bracket.
    #
    # @param body [String] the text between a literal's outer braces or brackets
    # @return [Array<String>] each item's raw text, stripped, with empty items dropped
    def split_items(body)
      items = []
      current = +""
      depth = 0
      quoting = false
      escaping = false

      body.each_char do |char|
        current << char
        next (escaping = false) if escaping
        next (escaping = true) if quoting && char == "\\"
        next (quoting = !quoting) if char == '"'
        next if quoting

        depth += 1 if "{[".include?(char)
        depth -= 1 if "}]".include?(char)
        next unless char == "," && depth.zero?

        current.chop!
        items << current
        current = +""
      end
      items << current
      items.map(&:strip).reject(&:empty?)
    end
  end
end
