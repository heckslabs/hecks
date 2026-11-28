# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"
require "hecks/tools/gate_memo/standalone"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `RegenerationRun` asks of the working tree: regenerating every corpus
      # domain's committed Rust output, and projecting the tools doc and the glossaries.
      #
      # It runs `Hecks::Tools::RegenerationRun` in this process: the run forks once for each
      # domain, a few at a time (`workers`, one per core unless told), and prints their output in
      # a fixed domain order. The domains share the bluebooks they attach, and each writes the same
      # bytes to them whichever runs first. With `check` it projects into a scratch copy of the
      # crate and compares, and never writes the tree. Without `confirm` the run is that same
      # check, so a regeneration that would rewrite tracked generated files reports drift and
      # writes only when it is confirmed.
      module Regeneration
        # Every operation this family carries out.
        OPERATIONS = %w[regenerate_corpus project_tools_doc project_glossary].freeze

        # How many lines of a script's output a refusal keeps.
        KEPT_LINES = 60

        # The line the script prints before regenerating, capturing how many domains it covers.
        REGENERATED_COUNT = /regenerating ([0-9]+) domain/

        module_function

        # Carries out the regeneration.
        #
        # @param operation [String] `regenerate_corpus`, `project_tools_doc` or `project_glossary`
        # @param held [Hash] the `RegenerationRun` record's fields: `check`, `confirm`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused: the tool runs in this process
        # @return [String] how many domains were checked or regenerated
        # @raise [ConsoleCapture::Failure] with the difference, when a check finds drift, or with
        #   what the script printed when it ends badly
        def call(operation, held, tree, shell: nil)
          project(operation, held, tree, RubyChild.new(tree), check_only?(held))
        end

        # @param child [RubyChild] the checkout's tool runner
        # @param check [Boolean] whether to only compare
        # @return [String] what the operation's tool printed, or the corpus verdict
        def project(operation, held, tree, child, check)
          case operation
          when "project_tools_doc" then project_written_files(operation, child, check)
          when "project_glossary" then project_glossary(child, held, check)
          else regenerate_remembered(child, tree, held, check)
          end
        end

        # A check of the whole corpus that is not confirmed is skipped when the gate or an earlier
        # check passed on the same files. A run that writes, or checks only some domains, always
        # runs.
        #
        # @return [String] the verdict, or that the check was skipped as unchanged
        def regenerate_remembered(child, tree, held, check)
          args = [*domains(held), *workers(held)]
          whole = check && args.empty? && !set?(held, :confirm)
          return regenerate(child, check, args) unless whole

          Tools::GateMemo::Standalone.guard(tree.root, "codegen_drift") { regenerate(child, check, args) }
        end

        # @param held [Hash] the `RegenerationRun` record's fields: `domains`
        # @return [Array<String>] the tool's argument naming the domains to run, empty for every one
        def domains(held)
          named = held[:domains].is_a?(Hash) ? held[:domains][:value] : held[:domains]
          named.to_s.empty? ? [] : ["domains=#{named}"]
        end

        # @param held [Hash] the `RegenerationRun` record's fields: `workers`
        # @return [Array<String>] the tool's argument saying how many domains run at once, empty to
        #   leave it to the tool's default
        def workers(held)
          count = held[:workers].is_a?(Hash) ? held[:workers][:value] : held[:workers]
          count.to_s.empty? ? [] : ["workers=#{count}"]
        end

        # @param held [Hash] the record's fields: `check`, `confirm`
        # @return [Boolean] whether the run only compares: asked for, or not confirmed
        def check_only?(held)
          set?(held, :check) || !set?(held, :confirm)
        end

        # @param held [Hash] the record's fields
        # @param name [Symbol] a switch of the record
        # @return [Boolean] whether the switch was given as true
        def set?(held, name)
          (held[name].is_a?(Hash) ? held[name][:value] : held[name]) == true
        end

        # @param child [RubyChild] the checkout's tool runner
        # @param check [Boolean] whether to only compare
        # @param domains [Array<String>] `domains=a,b` when only those are to run and `workers=n`
        #   when told how many at once, else empty
        # @return [String] how many domains were checked or regenerated
        # @raise [ConsoleCapture::Failure] with the difference, or with what the script printed
        def regenerate(child, check, domains = [])
          result = child.capture("regen_codegen_domains", *("--check" if check), *domains)
          raise ConsoleCapture::Failure, refusal(result) unless result.ok?

          summary(result.out, check)
        end

        # Projects the `RetiredScript` rows into docs/tools.md and the module layout into the CLI
        # guides' command sections: a tool that writes files and with `check` only compares them.
        #
        # @param operation [String] `project_tools_doc`
        # @param child [RubyChild] the checkout's tool runner
        # @param check [Boolean] whether to only compare
        # @return [String] what the tool printed
        # @raise [ConsoleCapture::Failure] with the stale files, when a check finds drift
        def project_written_files(operation, child, check)
          child.answer(operation, *("--check" if check))
        end

        # @param child [RubyChild] the checkout's tool runner
        # @param held [Hash] the record's fields: `domain`, the directory, and `bluebook`, the name
        # @param check [Boolean] whether to only compare
        # @return [String] what the tool printed
        # @raise [ConsoleCapture::Failure] naming the drifted files, when a check finds drift
        def project_glossary(child, held, check)
          child.answer("project_glossary", plain(held[:domain]).to_s, plain(held[:bluebook]).to_s, *("--check" if check))
        end

        # @param argument [Hash, Object] a record field, wrapped as `value:` or bare
        # @return [Object] the bare value
        def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

        # @param output [String] what the script printed
        # @param check [Boolean] whether it only compared
        # @return [String] the verdict, with how many domains it covered
        def summary(output, check)
          count = output[REGENERATED_COUNT, 1]
          return "regenerated #{count} corpus domains into the checkout" unless check

          "checked #{count} corpus domains against a scratch crate: no drift " \
            "(add --confirm to regenerate into the checkout)"
        end

        # @param result [Shell::Result] how the script ended
        # @return [String] the last lines it printed: the difference, or why it stopped
        def refusal(result)
          printed = [result.out, result.err].join
          lines = printed.lines.map(&:chomp).reject(&:empty?)
          shown = lines.last(KEPT_LINES)
          note = lines.size > shown.size ? ["(the last #{shown.size} of #{lines.size} lines)"] : []
          [*note, *shown].join("\n")
        end
      end
    end
  end
end
