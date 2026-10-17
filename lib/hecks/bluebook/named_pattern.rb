module Hecks
  module Bluebook
    # The patterns a bluebook names instead of spelling: `attribute :slug, String, matches: :snake_name`
    # says what `pattern: '^[a-z][a-z0-9_]*$'` does. A name stands for exactly its regex, so the IR,
    # the generated Rust and the runtime check see the pattern and never the name.
    #
    # `rust/parser/src/build/named_pattern.rs` holds the same table; spec/named_pattern_spec.rb
    # holds the two to each other.
    module NamedPattern
      # Name => the regex source it stands for. Each is the exact source the corpus spelled by hand.
      TABLE = {
        present:       '[^ \t\n\r]',
        not_empty:     '[^\t\n\r]',
        no_whitespace: '^[^ \t\n\r]+$',
        snake_name:    "^[a-z][a-z0-9_]*$",
        git_sha:       "^[0-9a-fA-F]{7,40}$",
        digits:        "^[0-9]+$"
      }.freeze

      module_function

      # @param name [Symbol, String] a name in TABLE
      # @return [String] the regex source it stands for
      # @raise [ArgumentError] when the name is not one the language gives
      def source(name)
        TABLE.fetch(name.to_sym) do
          raise ArgumentError, "matches: #{name.inspect} is not a named pattern — " \
                               "the names are #{TABLE.keys.map(&:inspect).join(", ")}"
        end
      end
    end
  end
end
