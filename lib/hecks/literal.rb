module Hecks
  # THE ONE SPELLING FOR A CAPTURED RUBY LITERAL ON THE WIRE.
  #
  # Several `to_h` fields hold a value the author wrote in a bluebook —
  # `where(status: { eq: "open" })`, `then_set append: { direction: { value:
  # "credit" } }`, `dispatch ... with: { number: :source }`, an attribute's
  # `default:` — as TEXT, because the export has to stand on its own and a
  # String field cannot say "this one was a Symbol". Every such field is the
  # same question and now gets the same answer.
  #
  # It was three answers before, and they disagreed on both axes that matter.
  # `Mutation#appended_fields` spelled a Symbol BARE and everything else
  # `inspect`; `QuerySpecification.render_value` spelled a Symbol with a COLON
  # and everything else `to_s`. So `:amount` crossed as "amount" in a mutation
  # and ":amount" in a saga binding — the same value, two spellings, and each
  # reader had to know which field it was looking at. Worse, `to_s`/`inspect`
  # on a Hash is Ruby's OWN rendering, which moved under us: 3.3 writes
  # `{:value=>"credit"}` and 3.4 writes `{value: "credit"}` for the identical
  # Hash, so the wire format was silently pinned to an interpreter version.
  #
  # SELF-DESCRIBING IS THE RULE, stated once here rather than inherited from
  # whatever `inspect` happens to do: a symbol wears its colon, a string wears
  # its quotes, a hash wears `{key: value}` braces, a list wears its brackets,
  # and a number, a boolean and nil are bare. `read` is the exact inverse, and
  # is the only thing that should ever take one of these strings apart.
  module Literal
    module_function

    def render(value)
      case value
      when nil            then "nil"
      when true, false    then value.to_s
      when Symbol         then ":#{value}"
      when Integer, Float then value.to_s
      when String         then quote(value)
      when Hash           then "{#{value.map { |key, held| "#{key}: #{render(held)}" }.join(', ')}}"
      when Array          then "[#{value.map { |held| render(held) }.join(', ')}]"
      else
        raise ArgumentError, "#{value.class} has no pinned literal spelling — teach Literal.render one " \
                             "rather than letting #to_s decide it"
      end
    end

    # Read one back. Tolerant of a bare word on purpose: the language stores a
    # closed set's members and a few hand-written fields as plain text that was
    # never rendered, and those must stay the strings they are.
    def read(text)
      raw = text.to_s.strip
      return nil if raw.empty? || raw == "nil"
      return true if raw == "true"
      return false if raw == "false"
      return raw.to_i if raw.match?(/\A-?\d+\z/)
      return raw.to_f if raw.match?(/\A-?\d+\.\d+\z/)
      return raw[1..].to_sym if raw.start_with?(":")
      return unquote(raw) if quoted?(raw)
      return read_hash(raw) if raw.start_with?("{") && raw.end_with?("}")
      return read_array(raw) if raw.start_with?("[") && raw.end_with?("]")

      raw
    end

    ESCAPED = { '"' => '\\"', "\\" => "\\\\" }.freeze

    def quote(text) = "\"#{text.gsub(/["\\]/) { |char| ESCAPED[char] }}\""

    def quoted?(raw) = raw.length >= 2 && raw.start_with?('"') && raw.end_with?('"')

    def unquote(raw) = raw[1..-2].gsub(/\\(.)/) { ::Regexp.last_match(1) }

    def read_hash(raw)
      split_items(raw[1..-2]).to_h do |item|
        key, _, held = item.partition(":")
        [key.strip.to_sym, read(held)]
      end
    end

    def read_array(raw) = split_items(raw[1..-2]).map { |item| read(item) }

    # Split on the commas that are actually SEPARATORS — never one inside a
    # quoted string or a nested brace/bracket. Scanned rather than
    # `String#split(", ")`, which tore `"a, b"` in half and lost the second
    # field of anything nested.
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
