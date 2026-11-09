# frozen_string_literal: true

require "stringio"
require_relative "../shell"

module Hecks
  module Adapters
    class Dispatching
      # Runs a launcher line against the registry the filling already runs in, so a step is the
      # bluebook's command dispatched here and not a new `exe/hecks` process that boots the whole
      # domain to dispatch it.
      #
      # It answers what a child launcher would: the same line goes through the same `CliRunner`,
      # and the answer is a {Shell::Result} whose stdout is the record the command printed and
      # whose stderr is the refusal, so `StepOutcome` judges it as it judges a child's. Two things
      # a child gave for free are done by hand. The cascade starts at depth zero, as a fresh
      # process does, so the reactions of a step are not cut off by the cascade that began the
      # filling; and the ambient caller is cleared, as it is for a reaction, so the role that
      # began the filling neither satisfies nor blocks a step.
      class InProcessRunner
        # How a finished line ended, in the two methods {Shell::Result} asks of a status.
        Status = Struct.new(:success?, :exitstatus)

        # @param registry [Runtime::Registry] the booted registry the commands dispatch on
        # @param program [String] the name a line's help and hints are shown under
        def initialize(registry, program: "hecks")
          @registry = registry
          @program = program
        end

        # Whether a line run here does what a child launcher in `repo` would: the registry is a
        # booted one and `repo` is the checkout this process stands in. A filling for another
        # checkout runs that checkout's own launcher.
        #
        # @param registry [Object, nil] what the adapter was bound to
        # @param repo [String, nil] the checkout the filling is for
        # @return [Boolean]
        def self.fits?(registry, repo)
          return false unless registry.is_a?(Runtime::Registry) && repo

          File.realpath(repo) == File.realpath(Dir.pwd)
        rescue SystemCallError
          false
        end

        # Runs one line.
        #
        # @param argv [Array<String>] the words after `exe/hecks`
        # @return [Shell::Result] the printed record and the refusal, with the line's status
        def call(argv)
          err = StringIO.new
          text, status, reason = run(argv, err)
          result(text.to_s, status, reason, err.string)
        rescue StandardError => e
          Shell::Result.new("", "#{e.class}: #{e.message}", Status.new(false, 1))
        end

        private

        def run(argv, err)
          at_depth_zero do
            Runtime::Caller.without do
              Driving::CliRunner.call(runtime: dispatcher, argv: argv.dup, program: @program, err: err)
            end
          end
        end

        def dispatcher = @dispatcher ||= Runtime::Dispatcher.new(@registry)

        # A line that failed with a settled record prints the record and says why on stderr; any
        # other failure is its text on stderr alone.
        def result(text, status, reason, noise)
          return Shell::Result.new(text, noise, Status.new(true, 0)) if status.to_i.zero?

          out = reason ? text : ""
          Shell::Result.new(out, [noise, reason || text].join, Status.new(false, status.to_i))
        end

        def at_depth_zero
          depth = Thread.current[:hecks_reaction_depth]
          Thread.current[:hecks_reaction_depth] = 0
          yield
        ensure
          Thread.current[:hecks_reaction_depth] = depth
        end
      end
    end
  end
end
