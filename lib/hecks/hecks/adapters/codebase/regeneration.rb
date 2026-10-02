# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `RegenerationRun` asks of the working tree: regenerating every corpus
      # domain's committed Rust output, and projecting the CI path gates into the workflows.
      #
      # It runs `Hecks::Tools::RegenerationRun` in this process: the run forks once for each
      # domain, in a fixed order, because the domains share the files they stamp. With `check` it
      # projects into a scratch copy of the crate and compares, and never writes the tree. Without
      # `confirm` the run is that same check, so a regeneration that would rewrite tracked generated
      # files reports drift and writes only when it is confirmed.
      module Regeneration
        # Every operation this family carries out.
        OPERATIONS = %w[regenerate_corpus project_ci_gates decide_ci_gate].freeze

        # How many lines of a script's output a refusal keeps.
        KEPT_LINES = 60

        module_function

        # Carries out the regeneration.
        #
        # @param operation [String] `regenerate_corpus` or `project_ci_gates`
        # @param held [Hash] the `RegenerationRun` record's fields: `check`, `confirm`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused: the tool runs in this process
        # @return [String] how many domains were checked or regenerated
        # @raise [ConsoleCapture::Failure] with the difference, when a check finds drift, or with
        #   what the script printed when it ends badly
        def call(operation, held, tree, shell: nil)
          flag = ->(name) { (held[name].is_a?(Hash) ? held[name][:value] : held[name]) == true }
          check = flag.call(:check) || !flag.call(:confirm)
          child = RubyChild.new(tree)
          return project_ci_gates(child, check) if operation == "project_ci_gates"
          return decide_ci_gate(child, held) if operation == "decide_ci_gate"

          result = child.capture("regen_codegen_domains", *("--check" if check))
          raise ConsoleCapture::Failure, refusal(result) unless result.ok?

          summary(result.out, check)
        end

        # @param child [RubyChild] the checkout's tool runner
        # @param check [Boolean] whether to only compare
        # @return [String] what the tool printed
        # @raise [ConsoleCapture::Failure] with the stale workflows, when a check finds drift
        def project_ci_gates(child, check)
          child.answer("project_ci_gates", *("--check" if check))
        end

        # @param child [RubyChild] the checkout's tool runner
        # @param held [Hash] the record's fields: `gate`, a `CiGate` row's name
        # @return [String] `touched=true` or `touched=false`
        # @raise [ConsoleCapture::Failure] when no row has that name
        def decide_ci_gate(child, held)
          gate = held[:gate].is_a?(Hash) ? held[:gate][:value] : held[:gate]
          child.answer("decide_ci_gate", "gate=#{gate}")
        end

        # @param output [String] what the script printed
        # @param check [Boolean] whether it only compared
        # @return [String] the verdict, with how many domains it covered
        def summary(output, check)
          count = output[/regenerating ([0-9]+) domain/, 1]
          return "regenerated #{count} corpus domains into the checkout" unless check

          "checked #{count} corpus domains against a scratch crate: no drift " \
            "(add --confirm to regenerate into the checkout)"
        end

        # @param result [Shell::Result] how the script ended
        # @return [String] the last lines it printed: the difference, or why it stopped
        def refusal(result)
          lines = [result.out, result.err].join.lines.map(&:chomp).reject(&:empty?)
          shown = lines.last(KEPT_LINES)
          note = lines.size > shown.size ? ["(the last #{shown.size} of #{lines.size} lines)"] : []
          [*note, *shown].join("\n")
        end
      end
    end
  end
end
