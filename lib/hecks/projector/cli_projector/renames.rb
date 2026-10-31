module Hecks
  module Projector
    module CliProjector
      # The launcher's rename table: the old command names a bluebook's `launcher` setting lists as
      # `renamed`, each mapped to the command it became. An old spelling resolves to the new command
      # and the launcher prints the new spelling once; an entry may also translate old argument names.
      #
      # The table resolves through 8.0; its removal is recorded in docs/compatibility.md.
      module Renames
        # The old spellings a `renamed` table maps to the commands they became, in the snake form
        # the name index uses.
        #
        # @param commands [Hash{String => Hash}] the projected commands, keyed by snake-form name
        # @param renamed [Hash{String => String, Hash}, nil] old name to new name, or to a hash
        #   with `to:` and `arguments:` (old argument name to new)
        # @return [Hash{Symbol => Hash{String => String}}] `:command` and `:question`, each mapping an
        #   old spelling to the name it became
        # @raise [Bluebook::DSL::Malformed] if an entry names no projected command
        def renamed_aliases(commands, questions, renamed)
          Hash(renamed).each_with_object({ command: {}, question: {} }) do |(old, target), map|
            to = renamed_target(target)
            space = renamed_space(commands, questions, to, old)
            map[space][old.to_s] = to
          end
        end

        # The namespace a renamed name's target belongs to: a command, or a query when no command
        # has that name.
        #
        # @raise [Bluebook::DSL::Malformed] if the target is neither a command nor a query
        def renamed_space(commands, questions, to, old)
          return :command if commands.key?(to)
          return :question if questions.key?(to)

          raise Bluebook::DSL::Malformed, "renamed #{old.inspect} names no command or query"
        end

        # The argument renames of each old spelling, read by the launcher to translate `old=value`.
        #
        # @return [Hash{String => Hash{String => String}}] old spelling to its argument renames
        def renamed_arguments(renamed)
          Hash(renamed).each_with_object({}) do |(old, target), map|
            map[old.to_s] = renamed_entry(target)[:arguments].to_h.transform_keys(&:to_s)
          end
        end

        # The new command name an entry names.
        def renamed_target(target) = renamed_entry(target)[:to].to_s

        # An entry as a hash with symbol keys: a bare string names the command, and a hash gives
        # `to:` and, optionally, `arguments:`.
        def renamed_entry(target)
          target.is_a?(Hash) ? target.transform_keys(&:to_sym) : { to: target }
        end
      end
    end
  end
end
