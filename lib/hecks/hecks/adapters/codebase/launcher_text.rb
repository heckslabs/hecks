# frozen_string_literal: true

require "hecks/command_names"
require "hecks/workflow_pagination"
require "hecks/doc_staleness"
require "hecks/text"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `ConformanceRun` asks of the text that drives the launcher and GitHub: the
      # workflows, hooks, gate rows, specs and guides.
      #
      # Both checks read files in this process and write nothing. They look for the two ways such
      # text goes quietly wrong: a command name the launcher does not accept, and a count of
      # GitHub list items taken from the first page only.
      module LauncherText
        module_function

        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with each invocation the launcher would refuse
        def command_names(tree)
          runtime = Hecks.describe(tree.path("lib/hecks/hecks"))
          CommandNames.check(root: tree.root, runtime: runtime)
        rescue CommandNames::Failure => e
          raise ConsoleCapture::Failure, e.message
        end

        # @param tree [Tree] the working tree
        # @param held [Hash] the record's fields; `paths` limits what is read
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with each stale citation
        def doc_staleness(tree, held)
          field = held[:paths]
          paths = Text.comma_list(field.is_a?(Hash) ? field[:value] : field)
          DocStaleness.check(root: tree.root, paths: paths)
        rescue DocStaleness::Failure => e
          raise ConsoleCapture::Failure, e.message
        end

        # @param tree [Tree] the working tree
        # @return [String] the clean verdict
        # @raise [ConsoleCapture::Failure] with each list call that counts one page
        def workflow_pagination(tree)
          WorkflowPagination.check(root: tree.root)
        rescue WorkflowPagination::Failure => e
          raise ConsoleCapture::Failure, e.message
        end
      end
    end
  end
end
