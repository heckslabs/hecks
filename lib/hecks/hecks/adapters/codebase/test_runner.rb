# frozen_string_literal: true

require "stringio"
require_relative "tree"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # The `TestRunner` adapter: runs one spec example through the test runner in this process.
      #
      # It hands the runner one file and one example description, so a caller never quotes the
      # description for a shell. What the runner prints is captured and comes back as the answer;
      # a run that fails refuses with the same text.
      class TestRunner
        class << self
          # @return [#call, nil] takes `(args, err, out)` and answers the exit status; the test
          #   runner when nil. A spec replaces it so no example has to run to test what is asked.
          attr_accessor :runner

          # The runner is asked for from inside a command's own reaction cascade, and the
          # dispatcher keeps that cascade's depth on the thread. A run starts at depth zero, as a
          # plain run does, so work that cascades four deep is not cut off by the cascade that
          # launched it.
          #
          # @yield the work to run at depth zero
          # @return [Object] what the block answers
          def at_reaction_depth_zero
            depth = Thread.current[:hecks_reaction_depth]
            Thread.current[:hecks_reaction_depth] = 0
            yield
          ensure
            Thread.current[:hecks_reaction_depth] = depth
          end
        end

        # @param tree [Tree] the checkout whose spec is run
        def initialize(tree)
          @tree = tree
        end

        # Runs one example of one spec file, from the checkout's root.
        #
        # @param file [String] the spec file, relative to the checkout or absolute
        # @param example [String] part of the example's description
        # @param env [Hash{String => String}] variables the specs read, set for this run only
        # @return [String] what the runner printed when every matching example passed
        # @raise [ConsoleCapture::Failure] when the file is not there, or an example failed
        def run(file:, example:, env: {})
          path = File.expand_path(file, @tree.root)
          raise ConsoleCapture::Failure, "no such spec file #{file}" unless File.file?(path)

          report = with_env(env) { run_example(path, example) }
          raise ConsoleCapture::Failure, "the test runner printed nothing for #{file}" if report.empty?

          report
        end

        private

        # What the runner printed for the example, when it passed.
        def run_example(path, example)
          out = StringIO.new
          status = Dir.chdir(@tree.root) { at_reaction_depth_zero { runner.call(["--example", example, path], out, out) } }
          raise ConsoleCapture::Failure, out.string.strip unless status.zero?

          out.string.strip
        end

        def at_reaction_depth_zero(&) = self.class.at_reaction_depth_zero(&)

        # Sets the variables for the block and puts each back as it was.
        def with_env(env)
          before = env.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
          env.each { |name, value| ENV[name] = value }
          yield
        ensure
          before.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
        end

        def runner
          return self.class.runner if self.class.runner

          require "rspec/core"
          # A process that runs one example after another, as a resident server does, has to reset
          # RSpec between runs: its reporter keeps the first run's output stream, so a later run
          # would write into that and answer an empty report.
          lambda do |args, err, out|
            RSpec.reset
            RSpec::Core::Runner.run(args, err, out)
          end
        end
      end
    end
  end
end
