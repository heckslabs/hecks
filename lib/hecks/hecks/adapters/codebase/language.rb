# frozen_string_literal: true

require "json"
require_relative "tree"
require_relative "../shell"
require "hecks/projection_files"
require "hecks/grammar/evolve"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `LanguageRun` asks of the working tree: projecting the language's tables
      # and walking a word through its lifecycle.
      #
      # A projection is built in memory by {ProjectionFiles} (the same code the `hecks project_*`
      # scripts run) and compared with the tree; it writes only when confirmed. An evolution edits
      # the syntax tables through {Grammar::Evolve}: unconfirmed it is rehearsed against an
      # in-memory copy and reports the edit it would make; confirmed it regenerates the golden IR
      # and holds the gates in a child process, and puts every file back if a gate refuses.
      module Language
        # The projection each operation runs.
        PROJECTIONS = {
          "project_model"             => :model,
          "project_vocabulary"        => :vocabulary,
          "project_rust_vocabulary"   => :rust_vocabulary,
          "project_reserved_names"    => :reserved_names,
          "project_parser_table"      => :parser_table,
          "project_bootstrap_table"   => :bootstrap_table,
          "project_field_hints"       => :field_hints,
          "project_expression_tables" => :expression_tables,
          "project_reference"         => :reference
        }.freeze

        # The status each word or argument operation moves a row to.
        STATUSES = { "admit" => "admitted", "deprecate" => "deprecated", "retire" => "retired",
                     "admit_argument" => "admitted", "deprecate_argument" => "deprecated",
                     "retire_argument" => "retired" }.freeze

        # Every operation this family carries out.
        OPERATIONS = (PROJECTIONS.keys + %w[propose rename propose_argument] + STATUSES.keys).freeze

        # The specs that hold a grammar edit: the syntax rows agree with the builder, the lifecycle
        # holds, and the golden IR is the one the language produces.
        GATES = %w[spec/syntax_conformance_spec.rb spec/syntax_lifecycle_spec.rb spec/ir_golden_spec.rb].freeze

        # The golden IR a grammar edit regenerates.
        GOLDEN = "spec/golden/ir/Bluebook.json"

        # What the tool says after a proposal or a rename, which still needs hand work.
        FOLLOW_UP = {
          "propose"          => "Proposed. It reaches no projection until admitted. Before `hecks admit`:\n  " \
                                "1. teach the %<context>s builder the word (and its spec/dsl_spec example)",
          "rename"           => "Renamed. The old spelling keeps parsing — that is the point. Before this holds:\n  " \
                                "1. alias the new word to the old in the %<context>s builder " \
                                "(alias_method :%<new_name>s, :%<word>s)\n  " \
                                "2. add the identical-IR example to spec/dsl_spec.rb",
          "propose_argument" => "Proposed. It reaches no projection until admitted. Before " \
                                "`hecks admit_argument`:\n  " \
                                "1. teach the %<context>s builder's %<word>s method the argument"
        }.freeze

        module_function

        # Carries out one operation.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `LanguageRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture] starts the gates' child process
        # @return [String] what was found, or done
        # @raise [ConsoleCapture::Failure] when the language refuses the edit, or a gate does
        def call(operation, held, tree, shell: Shell.new)
          args = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          return project(operation, args, tree) if PROJECTIONS.key?(operation)

          evolve(operation, args, tree, shell)
        end

        # Where every word stands: the rows not simply admitted, and the renamed ones.
        #
        # @return [String] a count, then a line for each row that is moving or renamed
        def word_status
          rows = Grammar::Evolve.keyword_rows
          moving = rows.reject { |row| row[:status] == "admitted" }
          renamed = rows.reject { |row| row[:was].to_s.empty? }
          [summary_line(rows, moving, renamed),
           *moving.map { |row| moving_line(row) }, *renamed.map { |row| renamed_line(row) }].join("\n")
        end

        # The count line that heads the report.
        def summary_line(rows, moving, renamed)
          "#{rows.size} keyword rows; #{moving.size} not simply admitted; #{renamed.size} renamed"
        end

        # The line for a row that is not simply admitted.
        def moving_line(row) = "  #{row[:status].ljust(10)} #{row[:context]}.#{row[:word]}"

        # The line for a row that carries a former name.
        def renamed_line(row) = "  renamed    #{row[:context]}.#{row[:word]} (was #{row[:was]})"

        # @param operation [String] a projection's operation
        # @param args [Hash] the record's plain fields
        # @param tree [Tree] the checkout
        # @return [String] the projected text for `stdout`, or the drift report
        # @raise [ConsoleCapture::Failure] when the language cannot be projected
        def project(operation, args, tree)
          result = ProjectionFiles.build(PROJECTIONS.fetch(operation), root: tree.root)
          return result.content.values.first if args[:stdout]

          tree.apply(result.content, stale: result.stale, confirm: args[:confirm] == true)
        rescue ProjectionFiles::Refused => e
          raise ConsoleCapture::Failure, e.message
        end

        # @param operation [String] a word or argument operation
        # @param args [Hash] the record's plain fields
        # @param tree [Tree] the checkout
        # @param shell [#capture] starts the gates
        # @return [String] the rehearsed edit, or the confirmed edit's outcome
        # @raise [ConsoleCapture::Failure] when the language or a gate refuses
        def evolve(operation, args, tree, shell)
          change = -> { Edits.edit(operation, args) }
          return rehearse(change, tree) unless args[:confirm] == true

          guarded(operation, args, tree, shell, change)
        rescue Grammar::Evolve::Refusal => e
          raise ConsoleCapture::Failure, e.message
        end

        # @param edit [#call] the edit to make
        # @param tree [Tree] the checkout
        # @return [String] each file the edit would change, with its lines added and removed
        def rehearse(edit, tree)
          changed = Grammar::Evolve.rehearse(&edit)
          lines = changed.map do |path, text|
            before = File.read(path).lines
            after = text.lines
            "  changed #{tree.relative(path)} (+#{(after - before).size} -#{(before - after).size} lines)"
          end
          ["dry run, #{changed.size} file changes (add --confirm to make them, regenerate the golden and hold the gates):",
           *lines].join("\n")
        end

        # Makes the edit, regenerates the golden and holds the gates; puts every file back if the
        # edit or a gate refuses.
        #
        # @param operation [String] the operation, for the follow-up it prints
        # @param args [Hash] the record's plain fields
        # @param tree [Tree] the checkout
        # @param shell [#capture] starts the child processes
        # @param edit [#call] the edit to make
        # @return [String] what the gates held, and what is left to do by hand
        # @raise [ConsoleCapture::Failure] when the edit or a gate refuses; nothing was changed
        def guarded(operation, args, tree, shell, edit)
          paths = Grammar::Evolve.syntax_paths + [tree.path(GOLDEN)]
          snapshots = paths.to_h { |path| [path, File.read(path)] }
          Grammar::Evolve.restore_on_raise(paths, &edit)
          regenerate(tree, shell)
          hold_gates(tree, shell, snapshots)
          ["#{args[:context]}.#{args[:word]} — the gates hold. Regenerated projections and the golden " \
           "are in the tree.", follow_up(operation, args)].compact.join("\n")
        end

        # Runs the gates, and puts every file back from `snapshots` when one refuses.
        #
        # @param snapshots [Hash{String => String}] each file's text before the edit
        # @raise [ConsoleCapture::Failure] when a gate refuses; nothing was changed
        def hold_gates(tree, shell, snapshots)
          gates = shell.capture("bundle", "exec", "rspec", *GATES, chdir: tree.root)
          return if gates.ok?

          snapshots.each { |path, text| File.write(path, text) }
          raise ConsoleCapture::Failure,
                "RESTORED — the gates refused, and the failures are the checklist. Nothing was " \
                "changed.\n#{[gates.out, gates.err].join.strip}"
        end

        # @param tree [Tree] the checkout
        # @param shell [#capture] starts the child process
        # @return [void]
        def regenerate(tree, shell)
          shell.capture("bundle", "exec", "rspec", "spec/ir_golden_spec.rb", env:   { "GOLDEN" => "rewrite" },
                                                                             chdir: tree.root)
        end

        # @param operation [String] the operation
        # @param args [Hash] the record's plain fields
        # @return [String, nil] what still needs hand work, if anything
        def follow_up(operation, args)
          text = FOLLOW_UP[operation] or return nil

          format(text, context: args[:context], new_name: args[:new_name], word: args[:word])
        end
      end
    end
  end
end
require_relative "language/edits"
