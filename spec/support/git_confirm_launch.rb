require "open3"
require "rbconfig"
require "tmpdir"

# The commands that move git state refuse without `--confirm`, in one wording (ADR 0163, plan
# steps 16 and 24). Each is launched through the real launcher as a subprocess in an empty
# directory with no remote and its own empty cache, so a guard that failed would still write
# nothing: `ReviewRequest.take!` past its guard would otherwise squash-merge a real pull request.
#
# The specs that launch them are three files, not one: each launch is a cold launcher boot, and
# the shard plan splits the suite by file, so one file of 22 boots was a shard of its own and the
# last job of every full CI run.
module GitConfirmLaunch
  # Each gated command and the arguments that take it to its guard.
  GATED = {
    "Landing.land!"       => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "Landing.retire!"     => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "Landing.discard!"    => ["branch.value=no-such", "checkout.value=/nonexistent-checkout", "reason.value=superseded"],
    "SendTrain.board!"    => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "Shipment.ship!"      => ["branch.value=no-such", "checkout.value=/nonexistent-checkout"],
    "ReviewRequest.open!" => ["branch.value=no-such"],
    "ReviewRequest.take!" => ["number.value=1"]
  }.freeze

  # What a refusal for a missing confirmation says.
  REFUSAL = "needs --confirm; without it this only reports".freeze

  def exe = File.expand_path("../../exe/hecks", __dir__)

  # @param argv [Array<String>] the command and its arguments
  # @return [Array(String, Integer)] what the launcher printed, and its exit status
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
end
