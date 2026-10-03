require_relative "../runtime/errors"

module Hecks
  module Doors
    # Turns `path=value` command-line words into a nested, typed argument Hash.
    # Types come from the projection, never from guessing at the value ("99" may be a String).
    module CliDoor
      # The words a Boolean is spelled with, and what each means.
      BOOLEAN_WORDS = { "true" => true, "yes" => true, "1" => true, "on" => true,
                        "false" => false, "no" => false, "0" => false, "off" => false }.freeze

      module_function

      # Builds a command's nested, typed argument Hash from its `name=value` words.
      #
      #   arguments(spec, ["reference.value=A-1", "sequence.value=99"])
      #   # => { reference: { value: "A-1" }, sequence: { value: 99 } }
      #
      # @param spec [Hash{Symbol => Object}] one command's entry from `Projector::CliProjector`
      # @param pairs [Array<String>] the words after the command: `name=value` pairs, where a path
      #   may be the short form of a single-field value object (`reference` for `reference.value`);
      #   `--name` for a Boolean; and at most one bare word, which fills the first argument
      # @return [Hash{Symbol => Object}] the arguments nested by path, leaves cast to type
      # @raise [Runtime::NotFound] if a path, flag or bare word does not fit the command
      # @raise [Runtime::TypeMismatch] if a value does not parse as its Integer or Float
      def arguments(spec, pairs)
        # Extra accepted arguments stay out of help, which teaches only to=....
        options = (spec[:arguments] + Array(spec[:legacy_arguments])).to_h do |argument|
          [argument[:path], argument]
        end

        normalize(spec, pairs, options).each_with_object({}) do |pair, args|
          path, value = split(pair)
          # key? rather than `||`, so the lookup below honors the same spelling `full` chose.
          full     = options.key?(path) ? path : expand(path, options)
          argument = options.key?(full) ? options[full] : raise(Runtime::NotFound, unknown(path, options.keys))

          next words(args, full.split("."), value, argument[:type]) if argument[:words]
          next append(args, full.split("."), cast(value, argument[:type])) if argument[:list]

          bury(args, full.split("."), cast(value, argument[:type]))
        end
      end

      # Rewrites the short forms into `name=value`: `--name` for a Boolean (a following `yes`,
      # `no`, `true`, `false`, `on`, `off`, `1` or `0` is that flag's value, not an argument),
      # `--name=value` as `name=value`, and one bare word as the command's first argument (`to` for
      # a command on an existing aggregate, the first attribute for one that creates).
      def normalize(spec, words, options)
        queue = words.dup
        pairs = []
        bare  = []
        until queue.empty?
          word = queue.shift
          if word.start_with?("--") && word.include?("=")
            pairs << underscored(word.delete_prefix("--"), options)
          elsif word.start_with?("--")
            path  = flag(word.delete_prefix("--"), options)
            value = BOOLEAN_WORDS.key?(queue.first.to_s.downcase) ? queue.shift : "true"
            pairs << "#{path}=#{value}"
          elsif word.include?("=")
            pairs << word
          else
            bare << word
            pairs << word
          end
        end
        raise Runtime::NotFound, too_many_bare(bare) if bare.length > 1

        pairs.map { |pair| bare.include?(pair) && !pair.include?("=") ? positional(pair, spec) : pair }
      end

      # A `name=value` pair whose name is spelled with dashes (`seed-start=3`), as the argument
      # spelled with underscores, unless an argument is named with the dashes.
      def underscored(pair, options)
        name, value = pair.split("=", 2)
        options.key?(name) ? pair : "#{name.tr('-', '_')}=#{value}"
      end

      # A `--name` flag, as the path of the Boolean argument it stands for. A dashed name
      # (`--gem-only`) is the argument spelled with underscores (`gem_only`).
      def flag(name, options)
        name = name.tr("-", "_") unless options.key?(name) || options.keys.any? { |key| key.start_with?("#{name}.") }
        path = options.key?(name) ? name : expand(name, options)
        return path if options.dig(path, :type) == "Boolean"

        raise Runtime::NotFound, "--#{name} is a flag, but this command has no Boolean argument #{name.inspect}"
      end

      # The one bare word, as a pair for the command's first argument the launcher does not mint.
      def positional(word, spec)
        first = spec[:arguments].find { |argument| !argument[:minted] }
        return "#{first[:path]}=#{word}" if first

        if spec[:arguments].any?
          raise Runtime::NotFound, "#{word.inspect} is not name=value; this command's only argument is its run key, " \
                                   "which is minted when omitted (run=<key> names one)"
        end

        raise Runtime::NotFound, "#{word.inspect} is not name=value, and this command takes no arguments"
      end

      # Words the refusal for more than one unnamed argument.
      def too_many_bare(bare)
        "only one argument may go unnamed, not #{bare.map(&:inspect).join(', ')}; name the rest as name=value"
      end

      # Cuts one word at its first `=`, so a value may itself contain `=`.
      def split(pair)
        name, value = pair.split("=", 2)
        raise Runtime::NotFound, "#{pair.inspect} is not name=value" if value.nil?

        [name, value]
      end

      # Expands a bare value-object name into the path of its only field.
      # Left unchanged when several fields match, since guessing which was meant is worse.
      def expand(path, options)
        candidates = options.keys.select { |key| key.start_with?("#{path}.") }
        candidates.length == 1 ? candidates.first : path
      end

      # Converts one value to its declared type; only Integer, Float and Boolean convert.
      def cast(value, type)
        case type
        when "Integer" then Integer(value)
        when "Float"   then Float(value)
        when "Boolean" then boolean(value)
        else value
        end
      rescue ArgumentError
        raise Runtime::TypeMismatch, "#{value.inspect} is not #{type} — the chapter declares this field as #{type}"
      end

      # Reads a Boolean word: `true`, `yes`, `1` or `on` is true; `false`, `no`, `0` or `off` is
      # false; case does not matter. Anything else is refused, since guessing would turn a typo
      # (`dry_run=ture`) into a silent false.
      #
      # @param value [String] the word
      # @return [Boolean]
      # @raise [Runtime::TypeMismatch] if the word is not one of those eight
      def boolean(value)
        BOOLEAN_WORDS.fetch(value.to_s.downcase) do
          raise Runtime::TypeMismatch,
                "#{value.inspect} is not Boolean — use true, false, yes, no, 1, 0, on or off"
        end
      end

      # Appends one element to a list argument, creating the list on first use.
      #
      # Repeats must grow the list (`bury` would silently keep only the last), and a single
      # element is still a one-item list, since a `list_of` attribute must never see a bare
      # object. Multi-field elements are left to `JsonDoor`: a flat command line cannot say
      # which `a.x=` pairs with which `a.y=`.
      def append(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        holder = branches[0..-2].reduce(hash) { |node, key| node[key] ||= {} }
        list   = holder[branches.last] ||= []

        list << { leaf => value }
        hash
      end

      # Adds the words of a `list_of` scalar argument to its Array: a comma-separated value is
      # several elements and a repeated name adds more, each cast to the element type. The
      # runtime refuses a lone scalar for a list, so the door is where every spelling becomes an
      # Array.
      #
      # @param hash [Hash{Symbol => Object}] the arguments built so far
      # @param path [Array<String>] the argument's dotted path
      # @param value [String] the word after `=`
      # @param type [String] the element type
      # @return [Hash{Symbol => Object}] `hash`
      def words(hash, path, value, type)
        *branches, leaf = path.map(&:to_sym)
        holder = branches.reduce(hash) { |node, key| node[key] ||= {} }
        list   = holder[leaf] ||= []
        list.concat(value.split(",").map { |word| cast(word.strip, type) })
        hash
      end

      # Sets one value at a nested path, creating intermediate Hashes and overwriting the leaf.
      def bury(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        target = branches.reduce(hash) { |node, key| node[key] ||= {} }
        target[leaf] = value
        hash
      end

      # Words the refusal for an argument the command does not take, listing what it does.
      def unknown(path, known)
        "no argument #{path.inspect} — this command takes #{known.sort.join(', ')}"
      end
    end
  end
end
