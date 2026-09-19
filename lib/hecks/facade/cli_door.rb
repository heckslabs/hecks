require_relative "../runtime/errors"

module Hecks
  module Facade
    # **The CLI door** — where Facade meets a caller holding flat strings.
    #
    # `JsonDoor` beside this one translates for a caller holding parsed JSON:
    # String keys, already-nested objects, real Integers. A command line has
    # neither of those. It has `sequence.value=99` — one flat string, with the
    # nesting spelled as a path and the type not spelled at all.
    #
    # So this does the two things that turns into: rebuild the nesting, and
    # give every leaf the type the chapter declared for it.
    #
    # The type comes from the projection, never from the value. A door that
    # guessed — "99 looks like a number" — would send the Integer 99 for a
    # version string of "99", and be wrong in a way nothing downstream could
    # detect, because both are perfectly good arguments. `Projector::CliProjector`
    # already read the declared field type out of the value object; this only
    # applies it.
    module CliDoor
      module_function

      # Builds a verb's nested, typed argument Hash out of the `name=value` words on a
      # command line.
      #
      # `["reference.value=BUG#1", "sequence.value=99"]` against a projected
      # verb spec -> `{ reference: { value: "BUG#1" }, sequence: { value: 99 } }`
      #
      # @param spec [Hash{Symbol => Object}] one verb's entry from `Projector::CliProjector`;
      #   read for `:arguments` and the optional `:legacy_arguments`, each an Array of
      #   option Hashes with `:path`, `:type` and, for a list, `:list`
      # @param pairs [Array<String>] the words after the verb, each `path=value`; a path
      #   may be the short form of a single-field value object (`reference` for
      #   `reference.value`)
      # @return [Hash{Symbol => Object}] the arguments nested by path, each leaf cast to
      #   its declared type and each list option collected into an Array; `{}` for no pairs
      # @raise [Runtime::NotFound] if a pair has no `=`, or names a path the verb does
      #   not take
      # @raise [Runtime::TypeMismatch] if a value cannot be read as the declared Integer
      #   or Float
      def arguments(spec, pairs)
        # Legacy options are accepted but not printed in help. This lets an
        # existing id=... aggregate invocation cross the new receiver boundary
        # while the projected surface teaches to=... exclusively.
        options = (spec[:arguments] + Array(spec[:legacy_arguments])).to_h do |argument|
          [argument[:path], argument]
        end

        pairs.each_with_object({}) do |pair, args|
          path, value = split(pair)
          # key? first, never `||` — full names whichever spelling (the
          # bare path, or its one-argument expansion) actually declares
          # this option, and the lookup below must hold to that same
          # decision rather than re-guessing which one exists.
          full     = options.key?(path) ? path : expand(path, options)
          argument = options.key?(full) ? options[full] : raise(Runtime::NotFound, unknown(path, options.keys))

          next append(args, full.split("."), cast(value, argument[:type])) if argument[:list]

          bury(args, full.split("."), cast(value, argument[:type]))
        end
      end

      # Cuts one command-line word at its first `=`, so a value may itself contain `=`.
      #
      # @param pair [String] one word, such as `"reference.value=BUG#1"`
      # @return [Array(String, String)] the path and the value; the value is `""` for
      #   `"name="`
      # @raise [Runtime::NotFound] if the word contains no `=`
      def split(pair)
        name, value = pair.split("=", 2)
        raise Runtime::NotFound, "#{pair.inspect} is not name=value" if value.nil?

        [name, value]
      end

      # Expands a bare value-object name into the full path of its only field.
      #
      # The short form, for the common case. Almost every value object in this
      # corpus has exactly one field, so `reference=BUG#1` is unambiguous and
      # is what anybody types. Expanded only when precisely one option starts
      # with that prefix — two would be a guess, and a guess about which field
      # a caller meant is worse than asking them to say.
      #
      # @param path [String] the path as typed, such as `"reference"`
      # @param options [Hash{String => Hash}] the verb's options keyed by full path
      # @return [String] the one full path beginning `"#{path}."`, or `path` unchanged when
      #   none or several do
      def expand(path, options)
        candidates = options.keys.select { |key| key.start_with?("#{path}.") }
        candidates.length == 1 ? candidates.first : path
      end

      # Converts one command-line value to the type the chapter declares for its field.
      #
      # @param value [String] the text after the `=`
      # @param type [String] the declared type name; `"Integer"`, `"Float"` and
      #   `"Boolean"` are converted, anything else leaves the value a String
      # @return [Integer, Float, Boolean, String] the typed value; a Boolean is true only
      #   for `true`, `yes` or `1` in any letter case, and false for every other text
      # @raise [Runtime::TypeMismatch] if the text does not parse as the declared Integer
      #   or Float
      def cast(value, type)
        case type
        when "Integer" then Integer(value)
        when "Float"   then Float(value)
        when "Boolean" then %w[true yes 1].include?(value.downcase)
        else value
        end
      rescue ArgumentError
        raise Runtime::TypeMismatch, "#{value.inspect} is not #{type} — the chapter declares this field as #{type}"
      end

      # Adds one element to a list argument, creating the list on first use.
      #
      # A list grows rather than overwrites, and getting this wrong is silent.
      #
      # `tags.value=framework tags.value=model-checker` sent through `bury`
      # twice would store the second one alone — no refusal, no warning, one tag
      # simply gone. That is the failure the interview named first: not the
      # loud kind, the kind where a value is forgotten and the caller has no
      # way to notice.
      #
      # A list of one is still a list. `tags.value=flaky` produces
      # `[{ value: "flaky" }]`, not `{ value: "flaky" }`, because the chapter
      # declared a collection and a caller who sent one element did not
      # thereby declare a different shape. A bare object must never reach a
      # `list_of` attribute: everything downstream that walks
      # it — a query's `contains`, a projection, the Postgres adapter's own
      # array handling — is entitled to assume it can iterate.
      #
      # Multi-field elements are not supported here, deliberately. A flat
      # command line has no way to say which `a.x=` goes with which `a.y=`,
      # and inventing an index syntax would be a language nobody asked for.
      # Every list in this corpus is a list of single-field value objects; a
      # richer one is a job for `JsonDoor`, which has real nesting.
      #
      # @param hash [Hash{Symbol => Object}] the arguments built so far; mutated in place
      # @param path [Array<String>] the option's path segments, at least two: the last
      #   names the element's field, the one before it names the list
      # @param value [Integer, Float, Boolean, String] the cast value for the new element
      # @return [Hash{Symbol => Object}] `hash`, with `{ leaf => value }` appended to the
      #   Array at the list's key
      def append(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        holder = branches[0..-2].reduce(hash) { |node, key| node[key] ||= {} }
        list   = holder[branches.last] ||= []

        list << { leaf => value }
        hash
      end

      # Sets one value at a nested path, creating each intermediate Hash on the way and
      # overwriting whatever the leaf already held.
      #
      # @param hash [Hash{Symbol => Object}] the arguments built so far; mutated in place
      # @param path [Array<String>] the option's path segments, outermost first
      # @param value [Integer, Float, Boolean, String] the cast value to store at the leaf
      # @return [Hash{Symbol => Object}] `hash`, with the value set under Symbol keys
      def bury(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        target = branches.reduce(hash) { |node, key| node[key] ||= {} }
        target[leaf] = value
        hash
      end

      # Words the refusal for an argument the verb does not take, listing what it does.
      #
      # @param path [String] the path as the caller typed it
      # @param known [Array<String>] every path the verb accepts, in any order
      # @return [String] a one-line message naming `path` and the sorted accepted paths
      def unknown(path, known)
        "no argument #{path.inspect} — this verb takes #{known.sort.join(', ')}"
      end
    end
  end
end
