# frozen_string_literal: true

require "hecks/vendoring/git_environment"
require_relative "../shell"

module Hecks
  module Adapters
    class MainIntegration
      # Runs one command in a directory for an integration step, with the variables that would
      # point it at another checkout, or let it push as the owner, left out. It answers whether
      # the command ended well and what it printed.
      class CommandRunner
        # The variables of the calling process that are never handed on: Bundler's, which would
        # run the command against the calling checkout, and the owner's push override.
        DROPPED = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYOPT RUBYLIB HECKS_OWNER_PUSH].freeze

        # @param argv [Array<String>] the command and its arguments
        # @param chdir [String] the directory it runs in
        # @return [Array(Boolean, String)] whether it ended with status zero, and what it printed:
        #   its standard output when it ended well, both streams when it did not
        def call(argv, chdir:)
          result = Shell.new.capture(*argv, env: environment, chdir: chdir)
          [result.ok?, result.ok? ? result.out : "#{result.out}#{result.err}"]
        end

        private

        def environment = Vendoring::GitEnvironment.clean.merge(DROPPED.to_h { |name| [name, nil] })
      end
    end
  end
end
