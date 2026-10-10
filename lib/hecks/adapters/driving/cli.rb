require_relative "../../runtime/errors"

module Hecks
  module Adapters
    module Driving
      # Turns `path=value` command-line words into a nested, typed argument Hash.
      # Types come from the projection, never from guessing at the value ("99" may be a String).
      module Cli
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
        # @param pairs [Array<String>] the words after the command: `name=value` pairs (a path may
        #   be the short form of a single-field value object), `--name` for a Boolean, and at most
        #   one bare word, which fills the first argument
        # @return [Hash{Symbol => Object}] the arguments nested by path, leaves cast to type
        # @raise [Runtime::NotFound] if a path, flag or bare word does not fit the command
        # @raise [Runtime::TypeMismatch] if a value does not parse as its Integer or Float
        def arguments(spec, pairs)
          options = declared_options(spec)
          Shorthand.normalize(spec, pairs, options).each_with_object({}) { |pair, args| store(args, pair, options) }
        end

        # Every argument the command accepts, by path. Extra accepted arguments stay out of help,
        # which teaches only to=....
        def declared_options(spec)
          (spec[:arguments] + Array(spec[:legacy_arguments])).to_h { |argument| [argument[:path], argument] }
        end

        # Casts the value of one `name=value` pair and sets it into `args` at its path.
        def store(args, pair, options)
          path, value = split(pair)
          full, argument = declared_argument(path, options)
          keys = full.split(".")
          return words(args, keys, value, argument[:type]) if argument[:words]
          return Nesting.append(args, keys, cast(value, argument[:type])) if argument[:list]

          Nesting.bury(args, keys, cast(value, argument[:type]))
        end

        # The full path and declaration of the argument `path` names, expanding a value object's
        # short form. `key?` rather than `||`, so the lookup honors the same spelling `full` chose.
        def declared_argument(path, options)
          full = options.key?(path) ? path : expand(path, options)
          return [full, options[full]] if options.key?(full)

          raise Runtime::NotFound, unknown(path, options.keys)
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

        # Adds the words of a `list_of` scalar argument to its Array: a comma-separated value is
        # several elements and a repeated name adds more, each cast to the element type. The
        # runtime refuses a lone scalar for a list, so the adapter is where every spelling becomes
        # an
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

        # Words the refusal for an argument the command does not take, listing what it does.
        def unknown(path, known)
          "no argument #{path.inspect} — this command takes #{known.sort.join(", ")}"
        end
      end
    end
  end
end
require_relative "cli/nesting"
require_relative "cli/shorthand"
