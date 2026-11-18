# frozen_string_literal: true

require "json"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GithubBranchCi
      # One command in the coder's checkout, through the runner: a refusal names what was asked and
      # what the command printed.
      class GhCall
        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory the commands run in
        def initialize(runner, checkout)
          @runner = runner
          @checkout = checkout
        end

        # @param argv [Array<String>] the command
        # @param what [String] what the command does, for a refusal
        # @return [String] what it printed
        # @raise [ConsoleCapture::Failure] when it fails
        def run!(argv, what)
          ok, output = @runner.call(argv, chdir: @checkout)
          raise ConsoleCapture::Failure, "#{what} failed: #{output.to_s.strip}" unless ok

          output.to_s
        end

        # @param path [String] a REST path under `repos/{owner}/{repo}/`
        # @param fields [Array<String>] `gh api` field flags, such as `-f`, `name=value`
        # @return [Object] the parsed answer
        # @raise [ConsoleCapture::Failure] when `gh` fails
        def api(path, *fields)
          JSON.parse(run!(["gh", "api", *fields, "repos/{owner}/{repo}/#{path}"], "gh api #{path}"))
        end
      end
    end
  end
end
