require_relative "../../../runtime/errors"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # The command line a `run` call stands for: the command word, one `path=value` word per
        # argument, then `--plan` and `--wait` when asked for. A word the caller writes never reads
        # as a flag, so `--confirm`, `-v` or `--stream` cannot be slipped in as a name.
        module LauncherLine
          # What a command word or argument name may not be: empty, led by a dash, or holding `=`
          # or a space.
          REFUSED_WORD = /\A\z|\A-|[=\s]/

          module_function

          # @param command [String, nil] the command as the launcher names it
          # @param args [Hash, nil] the arguments, nested objects read as dotted paths
          # @param wait [Boolean] whether to add `--wait`
          # @param plan [Boolean] whether to add `--plan`
          # @return [Array<String>] the launcher's argv
          # @raise [Runtime::TypeMismatch] when a word would read as a flag or a pair
          def argv(command, args, wait:, plan:)
            words = [word!(command, "command")] + pairs(args)
            words << "--plan" if plan
            words << "--wait" if wait
            words
          end

          # @param args [Hash, nil] the arguments, or one nested object of them
          # @param prefix [String, nil] the dotted path the object sits at
          # @return [Array<String>] one `path=value` word per scalar
          def pairs(args, prefix = nil)
            return [] if args.nil?
            raise Runtime::TypeMismatch, "args: must be an object of name and value" unless args.is_a?(Hash)

            args.flat_map do |name, value|
              path = [prefix, word!(name, "argument")].compact.join(".")
              value.is_a?(Hash) ? pairs(value, path) : ["#{path}=#{scalar(value)}"]
            end
          end

          # @param value [Object] one argument's value
          # @return [String] the value as the launcher reads it; a list is space-separated
          def scalar(value) = value.is_a?(Array) ? value.join(" ") : value.to_s

          # @param word [Object] a command word or argument name
          # @param kind [String] which one, for the refusal
          # @return [String] the word, when it can stand alone
          def word!(word, kind)
            text = word.to_s
            return text unless text.match?(REFUSED_WORD)

            raise Runtime::TypeMismatch, "#{kind}: #{text.inspect} is refused: a name never starts with a dash or holds " \
                                         "'=' or a space, so it cannot be read as a flag"
          end
        end
      end
    end
  end
end
