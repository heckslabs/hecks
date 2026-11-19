# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "red_flag_marker"

module Hecks
  module Adapters
    # What a wake of the orchestrator for a red main is weighed by: whether main's red flag stands
    # in the checkout's common git directory, the flag's id and the run a session for it takes, and
    # whether the checkout is the main one (its git directory is the common one) rather than a
    # linked worktree. The main checkout is read first, so a worktree never opens the marker.
    class RedWakeWeighing
      # The run a red-main session for a flag is keyed by: `red-wake-<flag id>`.
      PREFIX = "red-wake-"

      # @param checkout [String] the directory the wake names
      # @param clock [#call, nil] answers the current Time, for a spec
      def initialize(checkout, clock: nil)
        @checkout = checkout
        @clock = clock
      end

      # @return [Hash{Symbol => Object}] `standing:` and `main_checkout:` as booleans, `flag:` and
      #   `run:` as values
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def facts
        main = common_dir == own_dir
        flag = main ? marker.read : nil
        { standing: !flag.nil?, main_checkout: main,
          flag: { value: flag.to_h["id"].to_s }, run: { value: flag ? "#{PREFIX}#{flag["id"]}" : "" } }
      end

      private

      def marker = @clock ? RedFlagMarker.new(common_dir, clock: @clock) : RedFlagMarker.new(common_dir)

      def common_dir = @common_dir ||= rev_parse("--git-common-dir")

      def own_dir = rev_parse("--git-dir")

      def rev_parse(flag)
        ok = Git.new.capture("rev-parse", "--path-format=absolute", flag, chdir: @checkout)
        raise ConsoleCapture::Failure, "#{@checkout} is not a repository" unless ok.ok?

        File.expand_path(ok.out.strip)
      end
    end
  end
end
