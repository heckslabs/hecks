module Hecks
  module Adapters
    module Driving
      module Cli
        # Rewrites the shorthand spellings of a command line into plain `name=value` words.
        module Shorthand
          module_function

          # Rewrites the short forms into `name=value`: `--name` for a Boolean (a following `yes`,
          # `no`, `true`, `false`, `on`, `off`, `1` or `0` is that flag's value, not an argument),
          # `--name=value` as `name=value`, and one bare word as the command's first argument
          # (`to` for a command on an existing aggregate, the first attribute for one that creates).
          def normalize(spec, words, options)
            pairs, bare = collect(words, options)
            raise Runtime::NotFound, too_many_bare(bare) if bare.length > 1

            pairs.map { |pair| bare.include?(pair) && !pair.include?("=") ? positional(pair, spec) : pair }
          end

          # Every word as a pair, and the words that were neither a flag nor a pair.
          def collect(words, options)
            queue = words.dup
            pairs = []
            bare  = []
            until queue.empty?
              word = queue.shift
              pairs << pair_for(word, queue, options)
              bare << word if bare_word?(word)
            end
            [pairs, bare]
          end

          # A word that is neither a `--flag` nor a `name=value` pair.
          def bare_word?(word)
            !word.start_with?("--") && !word.include?("=")
          end

          # One word as a `name=value` pair; a `--flag` takes the Boolean word that follows it from
          # `queue`.
          def pair_for(word, queue, options)
            return word unless word.start_with?("--")
            return underscored(word.delete_prefix("--"), options) if word.include?("=")

            path  = flag(word.delete_prefix("--"), options)
            value = BOOLEAN_WORDS.key?(queue.first.to_s.downcase) ? queue.shift : "true"
            "#{path}=#{value}"
          end

          # A `name=value` pair whose name is spelled with dashes (`seed-start=3`), as the argument
          # spelled with underscores, unless an argument is named with the dashes.
          def underscored(pair, options)
            name, value = pair.split("=", 2)
            options.key?(name) ? pair : "#{name.tr("-", "_")}=#{value}"
          end

          # A `--name` flag, as the path of the Boolean argument it stands for. A dashed name
          # (`--gem-only`) is the argument spelled with underscores (`gem_only`).
          def flag(name, options)
            name = name.tr("-", "_") unless options.key?(name) || options.keys.any? { |key| key.start_with?("#{name}.") }
            path = options.key?(name) ? name : Cli.expand(name, options)
            return path if options.dig(path, :type) == "Boolean"

            raise Runtime::NotFound, "--#{name} is a flag, but this command has no Boolean argument #{name.inspect}"
          end

          # The one bare word, as a pair for the command's first argument the launcher does not
          # mint.
          def positional(word, spec)
            first = spec[:arguments].find { |argument| !argument[:minted] }
            return "#{first[:path]}=#{word}" if first

            if spec[:arguments].any?
              raise Runtime::NotFound, "#{word.inspect} is not name=value; this command's only argument is its run " \
                                       "key, which is minted when omitted (run=<key> names one)"
            end

            raise Runtime::NotFound, "#{word.inspect} is not name=value, and this command takes no arguments"
          end

          # Words the refusal for more than one unnamed argument.
          def too_many_bare(bare)
            "only one argument may go unnamed, not #{bare.map(&:inspect).join(", ")}; name the rest as name=value"
          end
        end
      end
    end
  end
end
