require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# The commands that move git state refuse without `--confirm`, in one wording (ADR 0163, plan
# steps 16 and 24). Each runs through the real launcher as a subprocess in an empty directory with
# no remote, so a guard that failed would still write nothing. The read-only status runs bang-less.
RSpec.describe "exe/hecks git-state confirmation", :io do
  def exe = File.expand_path("../exe/hecks", __dir__)

  def launch(*argv)
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |cache|
        env = { "HECKS_USAGE" => "off", "HECKS_CACHE_DIR" => cache, "LC_ALL" => "C.UTF-8",
                "HECKS_ENVIRONMENT" => nil, "PGHOST" => "127.0.0.1", "PGPORT" => "1", "PGPASSWORD" => nil }
        out, err, status = Open3.capture3(env, RbConfig.ruby, exe, *argv, chdir: root)
        [out + err, status.exitstatus]
      end
    end
  end

  gated = {
    "Landing.land!"       => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "Landing.retire!"     => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "Landing.discard!"    => ["branch.value=no-such", "checkout.value=/nonexistent-checkout", "reason.value=superseded"],
    "SendTrain.board!"    => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "Shipment.ship!"      => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "ReviewRequest.open!" => ["branch.value=no-such"],
    "ReviewRequest.take!" => ["number.value=1"]
  }

  gated.each do |command, args|
    it "refuses #{command} without --confirm, and says so", :aggregate_failures do
      text, status = launch(command, *args)
      expect(text).to include("needs --confirm; without it this only reports")
      expect(status).not_to eq(0)
    end
  end

  it "runs the read-only status without --confirm", :aggregate_failures do
    text, _status = launch("Checkout.status")
    expect(text).not_to include("needs --confirm")
  end

  gated.each do |command, args|
    it "passes the guard for #{command} with --confirm, and with confirm=true", :aggregate_failures do
      text, _status = launch(command, "--confirm", *args)
      expect(text).not_to include("needs --confirm")
      text, _status = launch(command, "confirm.value=true", *args)
      expect(text).not_to include("needs --confirm")
    end
  end
end
