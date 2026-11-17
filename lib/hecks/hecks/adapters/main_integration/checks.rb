# frozen_string_literal: true

require_relative "../checkout_gate"
require_relative "impacted_check"

module Hecks
  module Adapters
    class MainIntegration
      # The checks a verification runs in a clean copy of a landed commit: the quick gate, the same
      # gate `Landing.land!` ran (style, comments, generated-file specs, shape ledger), run there
      # to prove the commit builds as a clean checkout. It is the whole of what the listener
      # promises before a push, unless the shallow check is off (`ShallowCheck.switch!`): then the
      # landing ran no specs, and the verification runs the specs the landings since the last
      # verified commit touch ({ImpactedCheck}). The full suite, the command names, the CI
      # pipeline and the generated corpus run only in CI, on the train pull request, and a pull
      # request that fails there is the existing red path (a stopped run or a fix item).
      class Checks
        # What every launcher command runs under, as CI runs it: `bundle exec` hands Bundler to
        # each process the command starts, a spec's own subprocess included.
        RUNS_AS = %w[bundle exec].freeze

        # The launcher, as the copy holds it.
        LAUNCHER = CheckoutGate::LAUNCHER

        # The checks, by name: the copy's own gate.
        FIXED = { "quick gate" => CheckoutGate::ARGUMENTS }.freeze

        # @param directory [String] the clean copy the checks run in
        # @param changed [Array<String>] the paths the range being verified changed; read only by
        #   the impacted-spec check
        # @param since [String, nil] the commit the range starts after
        # @param shallow_off [Boolean] whether the shallow check is off, which adds the
        #   impacted-spec check
        # @param impacted [#call, nil] stands in for the impacted-spec run ({ImpactedCheck})
        def initialize(directory, changed = [], since: nil, shallow_off: false, impacted: nil)
          @directory = directory
          @changed = changed
          @since = since
          @shallow_off = shallow_off
          @impacted = impacted
        end

        # @return [Array<Array(String, Array<String>)>] each check's name and its command line;
        #   the impacted-spec check's is an {ImpactedCheck}, which answers `call` as a runner does
        def all
          checks = FIXED.map { |name, args| [name, [*RUNS_AS, LAUNCHER, *args]] }
          checks << [ImpactedCheck::NAME, impacted_check] if @shallow_off
          checks
        end

        private

        def impacted_check = ImpactedCheck.new(@directory, @changed, @since, run: @impacted)
      end
    end
  end
end
