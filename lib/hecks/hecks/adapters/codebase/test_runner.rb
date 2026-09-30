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
        end

        # @param tree [Tree] the checkout whose spec is run
        def initialize(tree)
          @tree = tree
        end

        # Runs one example of one spec file, from the checkout's root.
        #
        # @param file [String] the spec file, relative to the checkout or absolute
        # @param example [String] part of the example's description
        # @return [String] what the runner printed when every matching example passed
        # @raise [ConsoleCapture::Failure] when the file is not there, or an example failed
        def run(file:, example:)
          path = File.expand_path(file, @tree.root)
          raise ConsoleCapture::Failure, "no such spec file #{file}" unless File.file?(path)

          out = StringIO.new
          status = Dir.chdir(@tree.root) { runner.call(["--example", example, path], out, out) }
          raise ConsoleCapture::Failure, out.string.strip unless status.zero?

          out.string.strip
        end

        private

        def runner
          return self.class.runner if self.class.runner

          require "rspec/core"
          RSpec::Core::Runner.method(:run)
        end
      end
    end
  end
end
