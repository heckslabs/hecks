require_relative "../runtime/errors"

module Hecks
  module Facade
    # Turns `path=value` command-line words into a nested, typed argument Hash.
    # Types come from the projection, never from guessing at the value ("99" may be a String).
    module CliDoor
      module_function

      # Builds a verb's nested, typed argument Hash from its `name=value` words.
      #
      #   arguments(spec, ["reference.value=A-1", "sequence.value=99"])
      #   # => { reference: { value: "A-1" }, sequence: { value: 99 } }
      #
      # @param spec [Hash{Symbol => Object}] one verb's entry from `Projector::CliProjector`
      # @param pairs [Array<String>] the words after the verb; a path may be the short form
      #   of a single-field value object (`reference` for `reference.value`)
      # @return [Hash{Symbol => Object}] the arguments nested by path, leaves cast to type
      # @raise [Runtime::NotFound] if a pair has no `=` or names a path the verb lacks
      # @raise [Runtime::TypeMismatch] if a value does not parse as its Integer or Float
      def arguments(spec, pairs)
        # Extra accepted arguments stay out of help, which teaches only to=....
        options = (spec[:arguments] + Array(spec[:legacy_arguments])).to_h do |argument|
          [argument[:path], argument]
        end

        pairs.each_with_object({}) do |pair, args|
          path, value = split(pair)
          # key? rather than `||`, so the lookup below honors the same spelling `full` chose.
          full     = options.key?(path) ? path : expand(path, options)
          argument = options.key?(full) ? options[full] : raise(Runtime::NotFound, unknown(path, options.keys))

          next append(args, full.split("."), cast(value, argument[:type])) if argument[:list]

          bury(args, full.split("."), cast(value, argument[:type]))
        end
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
      # A Boolean is true only for `true`, `yes` or `1` in any letter case.
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

      # Sets one value at a nested path, creating intermediate Hashes and overwriting the leaf.
      def bury(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        target = branches.reduce(hash) { |node, key| node[key] ||= {} }
        target[leaf] = value
        hash
      end

      # Words the refusal for an argument the verb does not take, listing what it does.
      def unknown(path, known)
        "no argument #{path.inspect} — this verb takes #{known.sort.join(', ')}"
      end
    end
  end
end
