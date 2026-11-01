require "json"
require_relative "../usage_cache"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Every name the launcher accepts, by the scope it is typed in, for a check that reads text
        # rather than running a line. Extended into `CliRunner`.
        #
        # The index is the projection's own name table: the same one `hecks --all` lists from and
        # `resolve` looks a typed word up in, so a name the launcher would refuse is not in it. It
        # is worked out once and remembered through `UsageCache`, which keys it to the declarations
        # and the code that projects them.
        module NameIndex
          # The command line a remembered index stands for, which no real line can be.
          CACHE_LINE = ["--name-index"].freeze

          # The scope of the program's own bluebook; an attached bluebook's scope is its first word
          # (`deploy` for `hecks deploy ...`).
          OWN_SCOPE = "".freeze

          # @param runtime [#registry] a booted domain, or what `Hecks.describe` answers
          # @param program [String] how the caller is invoked
          # @return [Hash{String => Hash}] per scope: `"command"` and `"question"` map each accepted
          #   spelling to the name as listed, and `"modules"` lists the module words
          def name_index(runtime:, program: "hecks")
            text, = UsageCache.fetch(runtime, CACHE_LINE, program, audience: "maintainer") do
              [JSON.generate(scopes_of(runtime, program)), 0]
            end
            JSON.parse(text)
          end

          # @return [Hash{String => Hash}] every scope's table, worked out from the projections
          def scopes_of(runtime, program)
            own = { OWN_SCOPE => scope_table(runtime, [], program) }
            attached_bluebooks(runtime).each_with_object(own) do |name, scopes|
              word = Naming.snake(name)
              scopes[word] = scope_table(runtime, [word], program)
            end
          end

          # @return [Hash] one scope's `"command"`, `"question"` and `"modules"` tables
          def scope_table(runtime, argv, program)
            bluebook, _, program = bluebook_for(runtime, argv, program)
            launcher = LauncherOptions.settings(runtime, bluebook.name)
            options = LauncherOptions.projection(launcher, program).merge(audience(runtime, launcher, maintainer: true))
            cli = Projector.call(:cli, bluebook: bluebook, options: options)
            { "command" => listed(cli, :command, :commands), "question" => listed(cli, :question, :questions),
              "modules" => Projector::CliProjector.module_names(bluebook).map { |name| Naming.snake(name) } }
          end

          # @return [Hash{String => String}] each spelling of a kind, with the name as listed
          def listed(cli, kind, specs)
            cli[:names][kind].to_h do |spelling, id|
              [spelling, Projector::CliProjector.verb_form(cli[specs][id] || {}, spelling)]
            end
          end
        end
      end
    end
  end
end
