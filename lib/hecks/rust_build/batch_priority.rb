# frozen_string_literal: true

require_relative "world_rows"
require_relative "../hecks/adapters/codebase/holder_mark"

module Hecks
  module RustBuild
    # Where batch work runs: a command a heavy job starts (a gate check, a spec file's run) goes
    # under macOS's `taskpolicy -b`, Background QoS, so it takes the efficiency cores and the
    # disk's lower class, while residents, coders, the launcher and the owner's terminal keep
    # normal priority on every core. The Tickets world's `batch_priority` line, `qos: "background"`,
    # turns it on; `qos: "normal"` or no line leaves every command as it was.
    #
    # Only a command started inside a heavy-job place is wrapped ({HolderMark}), never one in CI,
    # off macOS, without `taskpolicy`, or already under it. The wrap goes outside `nice`, so the
    # priority is set before the build's own increment.
    module BatchPriority
      # The world verb that carries the setting.
      VERB = "batch_priority"

      # The `qos` value that puts batch work on the efficiency cores.
      BACKGROUND = "background"

      # The tool that sets a process's QoS on macOS.
      TOOL = "/usr/sbin/taskpolicy"

      module_function

      # @param argv [Array<String>] a command and its arguments
      # @param root [String] a hecks checkout, whose Tickets world carries the setting
      # @param base [#[]] the environment
      # @param platform [String] the Ruby platform
      # @param tool [String] the path of `taskpolicy`
      # @return [Array<String>] the command under `taskpolicy -b` when the world asks for it and
      #   the caller holds a heavy-job place, else the command itself
      def wrap(argv, root, base: ENV, platform: RUBY_PLATFORM, tool: TOOL)
        return argv unless platform.include?("darwin") && File.executable?(tool)
        return argv unless batch?(argv, base) && background?(root)

        [tool, "-b", *argv]
      end

      # @return [Boolean] whether a heavy job's own command, not one under the tool already
      def batch?(argv, base)
        Hecks::Adapters::Codebase::HolderMark.covers?(base) && base["CI"].to_s.empty? &&
          File.basename(argv.first.to_s) != "taskpolicy"
      end

      # @return [Boolean] whether the checkout's world sets `qos: "background"`
      def background?(root) = WorldRows.row(root, VERB)[:qos].to_s == BACKGROUND
    end
  end
end
