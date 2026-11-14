# frozen_string_literal: true

require_relative "../checkout_gate"

module Hecks
  module Adapters
    class MainIntegration
      # The checks a verification runs in a clean copy of a landed commit: the quick gate, the same
      # gate `Landing.land!` ran (style, comments, generated-file specs, shape ledger), run there
      # to prove the commit builds as a clean checkout. It is the whole of what the listener
      # promises before a push. The full suite, the command names, the CI pipeline and the
      # generated corpus run only in CI, on the train pull request, and a pull request that fails
      # there is the existing red path (a stopped run or a fix item).
      class Checks
        # What every launcher command runs under, as CI runs it: `bundle exec` hands Bundler to
        # each process the command starts, a spec's own subprocess included.
        RUNS_AS = %w[bundle exec].freeze

        # The launcher, as the copy holds it.
        LAUNCHER = CheckoutGate::LAUNCHER

        # The checks, by name: the copy's own gate.
        FIXED = { "quick gate" => CheckoutGate::ARGUMENTS }.freeze

        # @param directory [String] the clean copy the checks run in
        # @param changed [Array<String>] the paths the landed range changed; unused, since no
        #   check depends on what changed
        def initialize(directory, changed = [])
          @directory = directory
          @changed = changed
        end

        # @return [Array<Array(String, Array<String>)>] each check's name and its command line
        def all = FIXED.map { |name, args| [name, [*RUNS_AS, LAUNCHER, *args]] }
      end
    end
  end
end
