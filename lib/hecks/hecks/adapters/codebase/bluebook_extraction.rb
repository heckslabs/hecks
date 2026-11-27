# frozen_string_literal: true

require "open3"
require_relative "tree"
require_relative "changed_specs"
require "hecks/corpus"
require "hecks/tools/model_check"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `ConformanceRun` asks of the bluebooks a branch changed: each one boots into
      # a registry of its own, so a rule the IR cannot carry (a `given`, `where` or invariant whose
      # source did not survive extraction) is refused here, as it is when the branch is pushed.
      #
      # It lists, boots and reports; the refusals are the DSL's own and this decides nothing.
      module BluebookExtraction
        # The extension that marks a file as a bluebook.
        BLUEBOOK = /\.bluebook\z/
        # The Rust parser's own fixtures: grammar cases, some refused on purpose, never domains.
        PARSER_FIXTURES = %r{\Arust/parser/tests/fixtures/}

        module_function

        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param base [String] the ref the branch is compared against
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with each changed bluebook that was refused
        def call(tree, base: "origin/main")
          files = changed(tree, base)
          problems = sources(tree, files).filter_map { |source, named| refusal(source, named) }
          raise ConsoleCapture::Failure, problems.join("\n") unless problems.empty?

          "#{files.size} changed bluebook(s) booted, every rule extracted"
        end

        # A checkout with no `base` (a shallow clone) has nothing to compare with, so only what the
        # working tree changed since the head commit counts.
        #
        # @return [Array<String>] the bluebooks that differ from the merge-base with `base`, less
        #   the parser's fixtures
        def changed(tree, base)
          merge, status = Open3.capture2e("git", "-C", tree.root, "merge-base", "HEAD", base)
          ref = status.success? ? merge.strip : "HEAD"
          bluebooks = ChangedSpecs.changed_files(tree, ref).grep(BLUEBOOK).grep_v(PARSER_FIXTURES)
          bluebooks.select { |file| File.file?(File.join(tree.root, file)) }.sort
        end

        # A bluebook of a domain that loads as a directory (the Hecks domain's modules share one
        # namespace) boots with its directory, as the corpus boots it; any other boots alone.
        #
        # @return [Hash{String => Array<String>}] each path to boot, with the changed files it holds
        def sources(tree, files)
          members = Corpus.members(root: tree.root)
          files.group_by { |file| source_of(members, File.join(tree.root, file)) }
        end

        # A language bluebook refers to its siblings' aggregates, so it boots with its folder.
        #
        # @return [String] the corpus source holding the file, or the file itself
        def source_of(members, path)
          owner = members.find { |member| path == member.path || path.start_with?("#{member.path}/") }
          return File.dirname(path) if owner&.kind == :language

          (owner && Corpus.source_of(owner)) || path
        end

        # @return [String, nil] the changed files and what refused their source; nil when it booted
        def refusal(source, named)
          Tools::ModelCheck.boot(source)
          nil
        rescue StandardError => e
          "#{named.join(", ")}: #{first_line(e.message)}"
        end

        # @return [String] the first line of a refusal, which names the rule
        def first_line(message)
          line = message.lines.first
          line.to_s.strip
        end
      end
    end
  end
end
