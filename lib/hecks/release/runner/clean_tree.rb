require_relative "commands"

module Hecks
  module Release
    class Runner
      # The check that what a release ships is exactly what is committed: nothing modified,
      # untracked, or ignored under the paths the gem packages.
      #
      # `git status --porcelain` alone hides ignored files, and an ignored file under `lib/` or
      # `rust/` is one a build of the gem could carry. Build output (`target/`) is ignored on
      # purpose and never packaged, so it is not counted.
      class CleanTree
        # The repository paths the gem packages.
        SHIPPED = %w[lib rust exe qa/settings.yml].freeze

        # Ignored build output, which the gem leaves out.
        BUILD_OUTPUT = %r{(\A|/)target/?\z}

        # @param git [#read] runs a git command in the checkout and answers its output
        def initialize(git:)
          @git = git
        end

        # @return [Array<String>] each modified, untracked or ignored path under the packaged paths
        def stray
          lines = @git.read("status", "--porcelain", "--ignored", "--", *SHIPPED).lines.map(&:strip)
          lines.reject(&:empty?).map { |line| line.sub(/\A\S+\s+/, "") }.grep_v(BUILD_OUTPUT)
        end

        # @return [void]
        # @raise [Refusal] naming the first few stray paths
        def check!
          paths = stray
          return if paths.empty?

          raise Refusal, "#{paths.size} file(s) under #{SHIPPED.join(", ")} are modified, untracked or " \
                         "ignored (#{paths.first(5).join(", ")}); commit or delete them before releasing"
        end
      end
    end
  end
end
