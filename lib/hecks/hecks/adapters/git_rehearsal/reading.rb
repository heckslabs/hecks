# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      # The git reads a rehearsal makes: each answers what git printed or
      # refuses with what git said.
      #
      # An includer sets `@git` (the `Git` adapter) and `@checkout` (the repository's top level).
      module Reading
        private

        def read(*args, dir: @checkout)
          result = @git.capture(*args, chdir: dir)
          raise ConsoleCapture::Failure, "git #{args.first} failed in #{dir}: #{result.err.strip}" unless result.ok?

          result.out.strip
        end

        def short(commit) = commit[0, 9]
      end
    end
  end
end
