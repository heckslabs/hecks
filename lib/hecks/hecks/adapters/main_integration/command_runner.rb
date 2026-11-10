# frozen_string_literal: true

require "hecks/vendoring/git_environment"
require_relative "../bounded_capture"
require_relative "toolchain"

module Hecks
  module Adapters
    class MainIntegration
      # Runs one command in a directory for an integration step, with the variables that would
      # point it at another checkout, let it push as the owner or let its specs reach a live
      # service left out, and with rustup's `cargo` first on `PATH` (`Toolchain`). It answers
      # whether the command ended well and what it printed. A command that runs past the Tickets
      # world's `spec_bounds` `check_seconds` is ended with every process it started, and what it
      # printed ends with the spec file and example it was in, so the verification is refused
      # with that, as for any other failure.
      class CommandRunner
        # The variables of the calling process that are never handed on: Bundler's, which would
        # run the command against the calling checkout, the owner's push override, and the
        # opt-in to specs that reach a live service (spec/support/live_services.rb).
        DROPPED = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT RUBYLIB HECKS_OWNER_PUSH HECKS_LIVE_SERVICES].freeze

        # @param bound [Numeric, nil] the seconds one command may run; the world's
        #   `check_seconds` in the directory it runs in when nil
        def initialize(bound: nil)
          @bound = bound
        end

        # @param argv [Array<String>] the command and its arguments
        # @param chdir [String] the directory it runs in
        # @return [Array(Boolean, String)] whether it ended with status zero, and what it printed:
        #   its standard output when it ended well, both streams when it did not
        def call(argv, chdir:)
          result = bounded(chdir).call(argv, env: environment, chdir: chdir)
          [result.ok?, result.ok? ? result.out : "#{result.out}#{result.err}"]
        end

        private

        def bounded(chdir)
          seconds = @bound || BoundedCapture.seconds(chdir, :check_seconds)
          BoundedCapture.new(seconds: seconds, setting: "spec_bounds check_seconds")
        end

        def environment
          Vendoring::GitEnvironment.clean.merge(DROPPED.to_h { |name| [name, nil] }, Toolchain.environment)
        end
      end
    end
  end
end
