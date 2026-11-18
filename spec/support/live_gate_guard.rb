require "hecks/quality_control/adapters/main_maintenance"
require_relative "live_state_guard"

# Keeps every spec from running a main-maintenance step on the checkout itself. A submitted
# branch starts a maintenance run (`StartOnSubmission`, `GateOnStart`), and the `MainMaintenance`
# adapter answers it in this process: the quick gate on the checkout's `main` against the
# QualityControl ledger, then the reconcile and the push train through the checkout's launcher.
# A spec that boots the Hecks domain and submits work would do all of that for real, so the gate
# and the launcher refuse the checkout while a spec runs, and the run is refused by name. A spec
# of the steps themselves names a scratch repository, or stands in for the gate.
module LiveGateGuard
  # Raised when a spec reaches for a maintenance step on the checkout.
  class Violation < StandardError; end

  # @param root [String] the repository a step is about to act on
  # @return [Boolean] whether it is this checkout, or the main checkout this worktree belongs to
  def self.checkout?(root)
    expanded = File.expand_path(root.to_s)
    [LiveStateGuard::ROOT, File.dirname(LiveStateGuard.git_dir)].include?(expanded)
  end

  # @param root [String] the repository a step is about to act on
  # @param step [String] what the step is, for the message
  # @raise [Violation] when it is the checkout
  def self.refuse!(root, step)
    return unless checkout?(root)

    raise Violation, "a spec ran #{step} on the checkout #{root}; name a scratch repository, " \
                     "or stand in for the step"
  end

  # Prepended to the quick gate's entry point, refusing the checkout's own `main`.
  module GateRefusal
    def call(argv, root:, **options)
      LiveGateGuard.refuse!(root, "the quick gate on main")
      super
    end
  end

  # Prepended to the adapter's outside-world commands, refusing the checkout's launcher.
  module LaunchRefusal
    def launch(dir, root, *argv)
      LiveGateGuard.refuse!(root, "the maintenance command #{argv.first}")
      super
    end
  end
end

Hecks::QualityControlCli::QaMainGate.singleton_class.prepend(LiveGateGuard::GateRefusal)
Hecks::Adapters::MainMaintenance::Commands.singleton_class.prepend(LiveGateGuard::LaunchRefusal)
