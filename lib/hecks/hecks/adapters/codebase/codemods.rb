# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `CodemodRun` asks of the working tree: the mechanical rewrites of the
      # example bluebooks.
      #
      # Each codemod is a script built on `Hecks::Codemod` (`lib/hecks/codemod.rb`), which reboots
      # every bluebook it edits and puts the file back when the rewrite changes what the bluebook
      # means. The script runs in a child process from the checkout's root. Unconfirmed it runs
      # with `--dry-run`, which restores every file it touched, so tracked files stay changed only
      # when the request is confirmed.
      module Codemods
        # Every operation this family carries out.
        OPERATIONS = %w[hoist_local_givens drop_implicit_append_fields].freeze

        # The script each operation runs.
        SCRIPTS = { "hoist_local_givens"          => "codemod_hoist_local_givens",
                    "drop_implicit_append_fields" => "codemod_implicit_append_fields" }.freeze

        module_function

        # Carries out one codemod.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `CodemodRun` record's fields: `confirm`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] starts the script's child process
        # @return [String] what the script found for each example, and whether it rewrote it
        # @raise [ConsoleCapture::Failure] when the script ends badly
        def call(operation, held, tree, shell: nil)
          confirm = held[:confirm].is_a?(Hash) ? held[:confirm][:value] : held[:confirm]
          child = RubyChild.new(tree, shell: shell)
          return child.answer(SCRIPTS.fetch(operation)) if confirm == true

          "dry run, nothing kept (add --confirm to rewrite):\n#{child.answer(SCRIPTS.fetch(operation), '--dry-run')}"
        end
      end
    end
  end
end
