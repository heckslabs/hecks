# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Hecks
  module Adapters
    # The inbox of a dispatched session: one file per run, where an answer waits until the
    # session's own hooks hand it to the model. It is how an answer reaches a session that is
    # working without stopping it, since Claude Code offers no command that messages a running
    # session; a hook that exits 2 does reach it (after a tool call, or at the end of a turn).
    #
    # It decides nothing: whether a session is answered through its inbox is the bluebook's.
    class SessionInbox
      # Where the inboxes are kept unless a setting names another directory.
      DIRECTORY = "~/.claude/hecks-dev/inbox"

      # The line the model reads before the answer.
      HEADING = "Answer from the pipeline:"

      # @param directory [String, nil] the inbox directory (default `~/.claude/hecks-dev/inbox`)
      def initialize(directory: nil)
        @directory = File.expand_path(directory || DIRECTORY)
      end

      # @param run [String] the key of the run the session belongs to
      # @return [String] the file the run's answer waits in
      def path(run) = File.join(@directory, "#{run.to_s.tr("/", "_")}.md")

      # Leaves an answer for the session, written whole before it can be read: a hook never sees
      # half of it.
      #
      # @param run [String] the key of the run the session belongs to
      # @param answer [String] what the session is told
      # @return [String] the file it waits in
      def leave(run, answer)
        FileUtils.mkdir_p(@directory)
        target = path(run)
        File.write("#{target}.#{Process.pid}.tmp", answer.to_s)
        File.rename("#{target}.#{Process.pid}.tmp", target)
        target
      end

      # The hook command that hands a waiting answer to the model. The answer is moved aside
      # first, so two hooks never both hand it over and a second run finds nothing and exits 0;
      # a hook that found one prints it on stderr and exits 2, which Claude Code shows the model
      # (after a tool call, or instead of ending the turn).
      #
      # @param run [String] the key of the run the session belongs to
      # @return [String] the shell command
      def hook(run)
        file = Shellwords.escape(path(run))
        "f=#{file}; t=\"$f.$$\"; if mv \"$f\" \"$t\" 2>/dev/null; then " \
          "{ echo #{Shellwords.escape(HEADING)}; cat \"$t\"; } >&2; rm -f \"$t\"; exit 2; fi; exit 0"
      end
    end
  end
end
