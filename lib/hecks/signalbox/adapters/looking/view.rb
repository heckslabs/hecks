# frozen_string_literal: true

require "fileutils"
require "hecks/hecks/adapters/shell"

module Hecks
  module Adapters
    class Looking
      # The view a beat looks from: the copy's head, the tip of its repository's `main`, and how
      # many of the main checkout's machine-local files (`*.local.hecksagon`, `*.local.world`)
      # the copy lacks or holds with other content. It reads git and the file system and judges
      # nothing: Clearance's givens do.
      class View
        # The machine-local files a copy needs to read the same stores as the main checkout.
        LOCAL = ["**/*.local.hecksagon", "**/*.local.world"].freeze

        # The directories of the main checkout whose local files are never the copy's to hold.
        SKIPPED = [".claude/", "vendor/", "tmp/"].freeze

        # @param root [String] the copy the beat runs from
        # @param shell [Shell] runs git
        def initialize(root, shell: Shell.new)
          @root = root
          @shell = shell
        end

        # The push train's copy, the designated source of the beat.
        TRAIN_COPY = "hecks-train"

        # @return [Hash] `head:`, `main:` and `missing:`; the train copy's head is main's tip while
        #   it is detached at an ancestor of main, because the train moves it only between landings
        def facts
          main = git("rev-parse", "refs/heads/main")
          { head: train_behind?(main) ? main : git("rev-parse", "HEAD"), main: main, missing: missing }
        end

        private

        def train_behind?(main)
          File.basename(File.expand_path(@root)) == TRAIN_COPY && main != "unknown" &&
            @shell.capture("git", "merge-base", "--is-ancestor", "HEAD", main, chdir: @root).ok?
        rescue SystemCallError
          false
        end

        def missing
          primary = File.dirname(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
          return 0 if primary == "." || File.expand_path(primary) == File.expand_path(@root)

          locals(primary).count { |path| !same?(File.join(primary, path), File.join(@root, path)) }
        end

        def same?(original, copy) = File.exist?(copy) && FileUtils.compare_file(original, copy)

        def locals(directory)
          LOCAL.flat_map { |pattern| Dir.glob(pattern, base: directory) }
               .reject { |path| path.start_with?(*SKIPPED) }
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
