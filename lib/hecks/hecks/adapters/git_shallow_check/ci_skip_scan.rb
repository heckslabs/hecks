# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    class GitShallowCheck
      # Reads the spec files a landing changes for the one skip the owner's machine never shows: an
      # example that skips where a macOS-only tool is absent, which CI's Linux runner then skips
      # too, so the CI skip backstop (`spec/support/ci_skip_backstop.rb`) fails it.
      #
      # It is a static read, not a run: it names a changed spec file that both mentions a
      # macOS-only tool or path ({MAC_ONLY}) and holds a skip. A file tagged `zsh_completion` is
      # left out, since the CI job that routes that tag has the tool. It catches this known form,
      # not every skip; the backstop in CI remains the full check.
      module CiSkipScan
        # Tools and paths that exist on the owner's Mac and not on a Linux runner.
        MAC_ONLY = %r{/bin/zsh|\blaunchctl\b|\bosascript\b|~/Library|/Library/}

        # A changed spec file.
        SPEC_PATH = %r{\Aspec/.*_spec\.rb\z}

        # A line that skips or marks an example pending.
        SKIP = /\bskip:|^\s*(?:skip|pending)\b/

        # Tags a CI job routes to a runner that has the tool.
        ROUTED = /\bzsh_completion\b/

        # What a refusal opens with.
        HEAD = "CI skip scan (static)"

        module_function

        # @param checkout [String] the branch's worktree
        # @param paths [Array<String>] changed paths relative to the checkout
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming each skip line in a changed spec that mentions a
        #   macOS-only tool
        def call(checkout, paths)
          found = paths.grep(SPEC_PATH).flat_map { |path| skips(checkout, path) }
          return if found.empty?

          raise ConsoleCapture::Failure, "#{HEAD}: #{found.size} skip(s) that happen only where a macOS-only tool " \
                                         "is absent, so CI skips them with no destination " \
                                         "(spec/support/ci_skip_backstop.rb):\n  #{found.join("\n  ")}"
        end

        # @param checkout [String] the branch's worktree
        # @param path [String] a changed spec path
        # @return [Array<String>] `path:line text` for each skip of a file naming a Mac-only tool
        def skips(checkout, path)
          file = File.join(checkout, path)
          return [] unless File.file?(file)

          lines = File.readlines(file)
          return [] unless lines.any?(MAC_ONLY) && lines.none?(ROUTED)

          lines.each_with_index.filter_map { |line, at| "#{path}:#{at + 1} #{line.strip}" if line.match?(SKIP) }
        end
      end
    end
  end
end
