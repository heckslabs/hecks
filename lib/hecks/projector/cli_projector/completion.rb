module Hecks
  module Projector
    module CliProjector
      # `hecks completion <shell>` (ADR 0163, plan step 7): the words a shell completes, read from
      # the same listing the help prints, and the script that registers them. Nothing here is typed
      # by hand: a renamed command or a new module reaches the completions with the next projection.
      module Completion
        # The shells a completion script is written for. PowerShell is not among them (step 48).
        SHELLS = %w[bash zsh fish].freeze

        # The words a completion offers: the first word of a line (modules, the everyday names and
        # the launcher's own words), and per aggregate, its calls with the bang on commands.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook whose modules are offered
        # @param cli [Hash] the projection (`:commands`, `:questions`)
        # @param options [Hash] the listing's options, which decide the calls shown (`:everyday`)
        # @return [Hash{Symbol => Object}] `:first` (the words of the first place), `:calls` (the
        #   calls per aggregate name) and `:all` (every call, for a shell that filters by prefix)
        def completion_words(bluebook, cli, options)
          calls = shown_calls(cli, options).group_by { |spec| spec[:group] }
                                           .transform_values { |specs| specs.map { |spec| label(spec) } }
          { first: first_words(bluebook, options) + calls.keys.map { |name| "#{name}." },
            calls: calls, all: calls.values.flatten }
        end

        # The script a shell sources to complete the words, registered for the program's first word.
        #
        # @param shell [String] one of `SHELLS`
        # @param program [String] the launcher's name, such as `hecks`
        # @param words [Hash] what `completion_words` returned
        # @return [String, nil] the script, or nil for a shell this projection does not write
        def completion_script(shell, program, words)
          name = program.split.first
          case shell
          when "bash" then bash_script(name, words)
          when "zsh" then zsh_script(name, words)
          when "fish" then fish_script(name, words)
          end
        end

        # The calls the audience is shown, internal ones left out.
        def shown_calls(cli, options)
          [cli[:commands], cli[:questions]].flat_map do |table|
            CliAudience.audience_specs(table, options).values.reject { |spec| spec[:internal] }
          end
        end

        # The module names, the everyday names and the launcher's own words.
        def first_words(bluebook, options)
          modules = bluebook.modules.map { |row| Naming.snake(row.name) }.uniq
          modules + Array(options[:everyday]) + %w[search completion help --all --maintainer]
        end

        # A bash script: a function completing the current word, registered for the program.
        def bash_script(name, words)
          fn = "_#{name.tr("^A-Za-z0-9_", "_")}_complete"
          lines = ["#{fn}() {", %(  local cur="${COMP_WORDS[COMP_CWORD]}"), "  COMPREPLY=()", %(  case "$cur" in)]
          lines += words[:calls].map { |agg, calls| "    #{agg}.*) #{bash_reply(calls, "$cur")} ;;" }
          lines += ["    *) #{bash_reply(words[:first], "$cur")} ;;", "  esac", "}", "complete -F #{fn} #{name}"]
          "#{lines.join("\n")}\n"
        end

        # The bash assignment offering a list of words that start with the current one.
        def bash_reply(list, cur)
          %{COMPREPLY=( $(compgen -W '#{list.join(" ")}' -- "#{cur}") )}
        end

        # A zsh script: a function offering the same words through `compadd`.
        def zsh_script(name, words)
          lines = [
            "_#{name.tr("^A-Za-z0-9_", "_")}() {", "  local cur=$words[CURRENT]", "  case $cur in"
          ]
          lines += words[:calls].map { |agg, calls| "    #{agg}.*) compadd -- #{calls.map { |c| "'#{c}'" }.join(" ")} ;;" }
          lines += ["    *) compadd -- #{words[:first].map { |w| "'#{w}'" }.join(" ")} ;;", "  esac", "}"]
          lines << "compdef _#{name.tr("^A-Za-z0-9_", "_")} #{name}"
          "#{lines.join("\n")}\n"
        end

        # A fish script: every word offered for the program, fish filtering them by prefix.
        def fish_script(name, words)
          offered = (words[:first] + words[:all]).join(" ")
          "complete -c #{name} -f -a '#{offered}'\n"
        end
      end
    end
  end
end
