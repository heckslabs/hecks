# frozen_string_literal: true

require "rbconfig"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Ticking` port's adapter for `Ticker`: starts one detached process that sleeps the world's
    # period and dispatches `Ticker.tick!` through the launcher, over and over, until a dispatch is
    # refused. It measures time and dispatches; whether the chain goes on (the pull request is
    # still open, the beats are within the limit) is the bluebook's, which refuses a tick that is
    # not wanted.
    class Ticking
      # The Tickets world verb that carries the period in `seconds` and the allowance in `minutes`.
      VERB = "ticks"

      # Seconds between two ticks when the world names none.
      SECONDS = 20

      # Minutes a chain may tick when the world names none.
      MINUTES = 30

      # What the child runs: sleeps, dispatches one tick through the launcher with bare arguments
      # (`to=`, `tick=`, `beats=`), and when the launcher refuses records the chain's end with
      # `Ticker.stop!`, naming the refusal's first line, so a chain that ends is an event.
      # Each statement is one line: the lines are joined with `;` to pass the script to `ruby -e`.
      CHAIN = <<~RUBY.tr("\n", ";").freeze
        run, seconds, launcher = ARGV
        count = 0
        loop do
          sleep(seconds.to_f)
          count += 1
          tick = ["Ticker.tick!", "to=\#{run}", "tick=\#{run}-\#{count}", "beats=\#{count}"]
          out = IO.popen([launcher, *tick, { err: [:child, :out] }], &:read)
          next if $?.success?
          why = out.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("[hecks]") }.first.to_s
          system(launcher, "Ticker.stop!", "to=\#{run}", "ending=\#{why}", out: File::NULL, err: File::NULL)
          break
        end
      RUBY

      # @param registry [Runtime::Registry, nil] the booted registry whose world is read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `spawner:` starts the chain from its argument list (a stand-in in
      #   specs), `seconds:` and `minutes:` stand in for the world
      # @param root [String, nil] the checkout whose `exe/hecks` each tick dispatches through
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
        @root = root || Dir.pwd
      end

      # Starts the chain of ticks for a run.
      #
      # @param held [Hash] the `Ticker` record: `run`
      # @return [Hash{Symbol => Hash}] `limit:` how many beats the world's minutes allow
      # @raise [ConsoleCapture::Failure] when the checkout has no launcher to dispatch through
      def open(**held)
        launcher = File.join(@root, "exe", "hecks")
        raise ConsoleCapture::Failure, "no launcher at #{launcher}" unless File.executable?(launcher)

        spawner.call(*child(plain(held[:run]), launcher))
        { limit: { value: (minutes * 60 / seconds).ceil } }
      end

      private

      def child(run, launcher)
        [RbConfig.ruby, "-e", CHAIN, run, seconds.to_s, launcher]
      end

      def spawner = @standins[:spawner] || method(:detach)

      def detach(*argv)
        Process.detach(Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true))
      end

      def seconds = (@standins[:seconds] || declared[:seconds] || SECONDS).to_f

      def minutes = (@standins[:minutes] || declared[:minutes] || MINUTES).to_f

      def declared = @registry&.world("Tickets")&.for_verb(VERB) || {}

      def plain(value) = value.is_a?(Hash) ? value[:value].to_s : value.to_s
    end
  end
end
