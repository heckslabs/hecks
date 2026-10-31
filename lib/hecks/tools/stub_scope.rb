# frozen_string_literal: true

require "open3"
require_relative "../tools"

module Hecks
  module Tools
    # Blocks a push while a file it touches still carries a stub.
    #
    # A bug found mid-task is filed as a Finding and stubbed in the code, so the coder can keep going
    # locally. The stub is a comment that names the finding:
    #
    #   # hecks-stub: <finding key>        (Ruby)
    #   // hecks-stub: <finding key>       (Rust)
    #
    # A push to main fails while any file in the pushed range (`base...HEAD`) holds such a marker,
    # and a marker that names no finding fails too. Removing the marker is what the fix does, so
    # the gate clears when the QA fix lands. Only touched files are checked: an old stub elsewhere
    # does not block unrelated work.
    #
    #   hecks ... script=stub_scope              # base defaults to origin/main
    #   hecks ... script=stub_scope base=REF     # any other base
    module StubScope
      MARKER = %r{(?:#|//)\s*hecks-stub:(.*)\z}

      # Files that name the marker in order to define, test or document it, not to stub code.
      EXEMPT = %w[
        .githooks/pre-push
        lib/hecks/tools/stub_scope.rb
        spec/hecks/tools/stub_scope_spec.rb
      ].freeze

      # The `git grep` line shape: `HEAD:path:line:content`.
      GREP_LINE = /\AHEAD:(.+?):(\d+):(.*)\z/

      # One stub the push still carries.
      Stub = Struct.new(:path, :line, :key) do
        # @return [String] the stub as a message line
        def to_s
          named = key.empty? ? "names no finding" : "stub for #{key}"
          "#{path}:#{line}: #{named}"
        end
      end

      module_function

      # @param argv [Array<String>] an optional `base=REF`, or a bare ref
      # @param root [String] the checkout to check
      # @return [Integer] 0 when no touched file carries a stub; 1 when one does; 2 when git cannot
      #   say what the push touches
      def main(argv, root: Tools::ROOT, **)
        base = argv.map { |arg| arg.delete_prefix("base=") }.first || "origin/main"
        files = changed_files(base, root)
        return files if files.is_a?(Integer)

        lines = grep_stubs(files, root)
        return lines if lines.is_a?(Integer)

        stubs = find(lines)
        return 0 if stubs.empty?

        stubs.each { |stub| $stdout.puts stub.to_s }
        $stdout.puts "\n[stub_scope] #{stubs.size} stub(s) in files this push touches. Fix the finding and remove the marker before pushing to main."
        1
      end

      # The stubs in `git grep` output, with the exempt files left out.
      #
      # @param lines [Array<String>] lines in the `HEAD:path:line:content` shape
      # @return [Array<Stub>] each marker found, in order
      def find(lines)
        lines.filter_map do |text|
          match = GREP_LINE.match(text)
          next unless match && !EXEMPT.include?(match[1])

          marker = MARKER.match(match[3])
          next unless marker

          Stub.new(match[1], Integer(match[2]), marker[1].strip)
        end
      end

      # @return [Array<String>] the files this push adds or changes, or an exit status on failure
      def changed_files(base, root)
        out, status = Open3.capture2e("git", "diff", "--name-only", "--diff-filter=ACMR", "#{base}...HEAD", chdir: root)
        return report_git_failure(base, out) unless status.success?

        out.split("\n")
      end

      # @return [Array<String>] the marker lines in the files, as `git grep` names them
      def grep_stubs(files, root)
        return [] if files.empty?

        out, status = Open3.capture2e("git", "grep", "-n", "-e", "hecks-stub:", "HEAD", "--", *files, chdir: root)
        return [] if status.exitstatus == 1 # git grep exits 1 when nothing matches
        return report_git_failure("HEAD", out) unless status.success?

        out.split("\n")
      end

      def report_git_failure(ref, out)
        warn "[stub_scope] cannot read the push against #{ref}: #{out.strip}"
        2
      end
    end
  end
end
