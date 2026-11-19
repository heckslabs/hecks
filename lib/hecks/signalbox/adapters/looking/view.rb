# frozen_string_literal: true

require "hecks/hecks/adapters/shell"

module Hecks
  module Adapters
    class Looking
      # The view a beat looks from: the copy's head, the tip of its repository's `main`, and how
      # many of the main checkout's machine-local files (`*.local.hecksagon`, `*.local.world`)
      # the copy lacks. It reads git and the file system and judges nothing: Clearance's givens do.
      class View
        # The machine-local files a copy needs to read the same stores as the main checkout.
        LOCAL = ["**/*.local.hecksagon", "**/*.local.world"].freeze

        # @param root [String] the copy the beat runs from
        # @param shell [Shell] runs git
        def initialize(root, shell: Shell.new)
          @root = root
          @shell = shell
        end

        # @return [Hash] `head:`, `main:` and `missing:`
        def facts
          { head: git("rev-parse", "HEAD"), main: git("rev-parse", "refs/heads/main"), missing: missing }
        end

        private

        def missing
          primary = File.dirname(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
          return 0 if primary == "." || File.expand_path(primary) == File.expand_path(@root)

          locals(primary).count { |path| !File.exist?(File.join(@root, path)) }
        end

        def locals(directory)
          LOCAL.flat_map { |pattern| Dir.glob(pattern, base: directory) }
               .reject { |path| path.start_with?(".claude/", "vendor/", "tmp/") }
        end

        # A git read that fails answers `unknown`, which never equals another, so a beat whose view
        # cannot be read is refused clearance.
        def git(*)
          result = @shell.capture("git", *, chdir: @root)
          result.ok? && !result.out.strip.empty? ? result.out.strip : "unknown"
        rescue SystemCallError
          "unknown"
        end
      end
    end
  end
end
