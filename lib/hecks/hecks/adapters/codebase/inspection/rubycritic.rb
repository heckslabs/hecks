# frozen_string_literal: true

# Runs rubycritic with its git root taken from git.
#
# rubycritic finds the repository root by walking up to the first `.git` directory. A linked
# worktree has a `.git` file instead, so inside one nested in its main checkout the walk passes the
# worktree and stops at the main checkout's directory. Churn is then read from the wrong tree and
# comes back 0 for every file. Asking git for the top level answers right in either layout.
#
# Started as a program by `Inspection`: `ruby rubycritic.rb <rubycritic arguments>`.
require "rubycritic/cli/application"

module Hecks
  module Adapters
    module Codebase
      module Inspection
        # Gives rubycritic's churn the root git reports for the directory it runs in.
        module GitToplevel
          private

          # @return [String] the top level of the working tree the current directory is in
          def find_git_root
            root = `git rev-parse --show-toplevel`.strip
            root.empty? ? super : root
          end
        end
      end
    end
  end
end

RubyCritic::SourceControlSystem::Git::Churn.prepend(Hecks::Adapters::Codebase::Inspection::GitToplevel)

exit RubyCritic::Cli::Application.new(ARGV).execute
