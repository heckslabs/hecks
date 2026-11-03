module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Reads the spellings a line may give a command or query. The launcher indexes them by the
        # snake-case `aggregate.verb` the projection prints; the bluebook's own verb form, such as
        # `Hecks::SendTrain.Board`, reaches the same one. Extended into `CliRunner`.
        module VerbNames
          # A realm written before the aggregate: `Hecks::`.
          REALM = /\A(?:[A-Z]\w*::)+/

          # The spelling notices this process has already printed, keyed by the spelling typed, so
          # each
          # prints once.
          NOTED = Set.new

          # The name the projection indexes a typed name under: the name itself when it is one,
          # else its verb form read into snake case, else the name as typed, for the refusal to
          # name.
          #
          # @param cli [Hash] the projection, holding the `:names` it indexes
          # @param typed [String] the word typed, without its `!`
          # @return [String] the indexed name, or `typed` when none matches
          def canonical_name(cli, typed)
            [typed, *verb_form_names(typed)].find { |name| indexed?(cli, name) } || typed
          end

          # Says once, on standard error, that a line used an aggregate's former name and names the
          # spelling to use. Short-name aliases stay silent.
          #
          # @param cli [Hash] the projection
          # @param typed [String] the word typed, without its `!`
          # @param name [String] the name the index resolved the word to
          # @return [void]
          def note_former_name(cli, typed, name)
            spec = indexed_spec(cli, name)
            return unless former_spelling?(spec, typed)
            return unless NOTED.add?("spelling #{typed}")

            warn "hecks: #{typed} is the former name of #{spec[:command]}; use that spelling (this notice prints once)"
          end

          # The command or query a name in the index resolves to, or nil.
          def indexed_spec(cli, name)
            target = cli[:names][:command][name] || cli[:names][:question][name]
            cli[:commands][target] || cli[:questions][target]
          end

          # Whether the word typed begins with the former name of the aggregate its spec belongs to.
          def former_spelling?(spec, typed)
            return false unless spec && spec[:formerly]

            snake_form(typed).start_with?("#{Naming.snake(spec[:formerly])}.")
          end

          # A typed name as the projection spells it, to match what was typed against the names it
          # indexes: `Hecks::SendTrain.bord` as `send_train.bord`.
          #
          # @param typed [String] the word typed, without its `!`
          # @return [String] the realm dropped and each dotted segment in snake case
          def snake_form(typed) = snake_segments(typed).join(".")

          private

          # `Hecks::SendTrain.board` as `send_train.board`; a verb that names an entity's command,
          # `SendTrain.Launcher.Refresh`, also as `send_train.refresh`, the way the projection
          # exposes it.
          def verb_form_names(typed)
            segments = snake_segments(typed)
            [segments.join("."), [segments.first, segments.last].join(".")].uniq
          end

          def snake_segments(typed) = typed.sub(REALM, "").split(".").map { |segment| Naming.snake(segment) }

          def indexed?(cli, name)
            cli[:names][:command].key?(name) || cli[:names][:question].key?(name)
          end
        end
      end
    end
  end
end
