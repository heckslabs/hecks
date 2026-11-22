# frozen_string_literal: true

require "open3"
require_relative "tree"
require_relative "changed_specs"
require "hecks/tools/model_check"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `ConformanceRun` asks of the bluebooks a branch changed: each one boots into
      # a registry of its own, so a rule the IR cannot carry (a `given`, `where` or invariant whose
      # source did not survive extraction) is refused here, as it would be when the branch is pushed.
      #
      # It lists, boots and reports; the refusals are the DSL's own and this decides nothing.
      module BluebookExtraction
        module_function

        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param base [String] the ref the branch is compared against
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with each changed bluebook that was refused
        def call(tree, base: "origin/main")
          files = changed(tree, base)
          problems = files.filter_map { |file| refusal(tree, file) }
          raise ConsoleCapture::Failure, problems.join("\n") unless problems.empty?

          "#{files.size} changed bluebook(s) booted, every rule extracted"
        end

        # @return [Array<String>] the bluebooks that differ from the merge-base with `base` and exist
        def changed(tree, base)
          merge, status = Open3.capture2e("git", "-C", tree.root, "merge-base", "HEAD", base)
          ref = status.success? ? merge.strip : base
          ChangedSpecs.changed_files(tree, ref).grep(/\.bluebook\z/)
                      .select { |file| File.file?(File.join(tree.root, file)) }.sort
        end

        # @return [String, nil] the file and what refused it; nil when it booted
        def refusal(tree, file)
          Tools::ModelCheck.boot(File.join(tree.root, file))
          nil
        rescue StandardError => e
          "#{file}: #{e.message.lines.first.to_s.strip}"
        end
      end
    end
  end
end
