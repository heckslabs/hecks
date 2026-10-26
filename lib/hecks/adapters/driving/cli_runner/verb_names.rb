module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Reads the spellings a line may give a command or query. The launcher indexes them by the
        # snake-case `aggregate.verb` the projection prints; the bluebook's own verb form, such as
        # `Hecks::PushTrain.Board`, reaches the same one. Extended into `CliRunner`.
        module VerbNames
          # A realm written before the aggregate: `Hecks::`.
          REALM = /\A(?:[A-Z]\w*::)+/

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

          private

          # `Hecks::PushTrain.board` as `push_train.board`; a verb that names an entity's command,
          # `PushTrain.Launcher.Refresh`, also as `push_train.refresh`, the way the projection
          # exposes it.
          def verb_form_names(typed)
            segments = typed.sub(REALM, "").split(".").map { |segment| Naming.snake(segment) }
            [segments.join("."), [segments.first, segments.last].join(".")].uniq
          end

          def indexed?(cli, name)
            cli[:names][:command].key?(name) || cli[:names][:question].key?(name)
          end
        end
      end
    end
  end
end
