module Hecks
  module Bluebook
    # The patterns a bluebook names instead of spelling: `matches: :snake_name` says what
    # `pattern: '^[a-z][a-z0-9_]*$'` does. A name stands for exactly its regex, so the IR, the
    # generated Rust and the runtime check see the pattern and never the name.
    #
    # `rust/parser/src/build/named_pattern.rs` holds the same table; spec/named_pattern_spec.rb
    # holds the two to each other.
    module NamedPattern
      # Name => the regex source it stands for, each the exact source the corpus spelled by hand.
      TABLE = {
        present:       '[^ \t\n\r]',
        not_empty:     '[^\t\n\r]',
        no_whitespace: '^[^ \t\n\r]+$',
        snake_name:    "^[a-z][a-z0-9_]*$",
        git_sha:       "^[0-9a-fA-F]{7,40}$",
        digits:        "^[0-9]+$",
        identifier:    "^[A-Za-z][A-Za-z0-9_]*$",
        csv_list:      '^[^ \t\n\r,]+(,[^ \t\n\r,]+)*$',
        command_ref:   '^[A-Z][A-Za-z0-9]*::[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*$',
        host_port:     "^[A-Za-z0-9_-]+(:[0-9]+)?$",
        instance_id:   "^i-[0-9a-f]+$",
        hostname:      "^[A-Za-z0-9][A-Za-z0-9.-]*$",
        word_chars:    "^[A-Za-z0-9_]*$",
        version:       "^[0-9]+[.][0-9]+[.][0-9]+",
        http_scheme:   "^https?://",
        capitalized:   "[A-Z][A-Za-z0-9]*",
        single_line:   '[^\n\r]'
      }.freeze

      module_function

      # @param name [Symbol, String] a name in `TABLE`
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
