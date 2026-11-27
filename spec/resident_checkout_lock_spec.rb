require "spec_helper"
require "open3"
require "rbconfig"
require_relative "support/resident_launch"

# The checkout's lock is what keeps an example that changes the checkout (`:changes_checkout`)
# from retiring another group's resident in the middle of an example that needs it standing. The
# groups run in parallel workers, each in a sandbox of its own (`RunSandbox`), so the lock has to
# be the same file for every worker: one in a worker's own temporary directory excludes no one.
RSpec.describe "the spec processes' lock on the checkout" do
  # @return [String] the lock a fresh spec process names, in a sandbox of its own
  def lock_of_another_worker
    support = File.join(ResidentLaunch::ROOT, "spec/support")
    script = 'require "rspec/core"; require "run_sandbox"; require "resident_launch"; print ResidentLaunch::CHECKOUT_LOCK'
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(ResidentLaunch::ROOT, "lib"), "-I", support,
                                      "-e", script, chdir: ResidentLaunch::ROOT)
    raise "the other worker did not start: #{err}" unless status.success?

    out
  end

  it "lies outside this process's own sandbox" do
    expect(RunSandbox.inside?(ResidentLaunch::CHECKOUT_LOCK)).to be(false)
  end

  it "is the same file for another worker in a sandbox of its own" do
    expect(lock_of_another_worker).to eq(ResidentLaunch::CHECKOUT_LOCK)
  end
end
