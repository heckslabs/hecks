# frozen_string_literal: true

module Hecks
  module Adapters
    class GitTrain
      # The git reads every part of a boarding makes, in the checkout it was boarded from: each
      # answers what git printed or refuses with what git said.
      #
      # An includer sets `@git` (the `Git` adapter) and `@checkout` (the repository's top level).
      module Reading
        private

        def read(*args, dir: @checkout)
          result = @git.capture(*args, chdir: dir)
          raise ConsoleCapture::Failure, "git #{args.first} failed in #{dir}: #{result.err.strip}" unless result.ok?

          result.out.strip
        end

        def ancestor?(ancestor, descendant) = @git.ancestor?(ancestor, descendant, chdir: @checkout)

        def short(commit) = commit[0, 9]
      end
    end
  end
end
