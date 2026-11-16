require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/git_launcher"
require "hecks/hecks/adapters/desktop_alert"

# Boots the Hecks domain with the push train's adapters stubbed: a boarding is queued as a pull
# request, and watching it answers whatever the example sets.
module WatchedTrain
  KEY = { value: "watch-1" }.freeze
  QUEUED = { outcome: { value: "queued" }, checkout: { value: "/repo" }, boarded: { value: "abc" },
             commits: { value: 1 }, report: { value: "queued" } }.freeze
  FAILED = { outcome: { value: "checks_failed" }, report: { value: "rspec 1/4, lint" } }.freeze
  CLOSED = { outcome: { value: "closed" }, report: { value: "train/main-abc was closed unmerged" } }.freeze
  MERGED = { outcome: { value: "merged" }, checkout: { value: "/repo" }, boarded: { value: "abc" },
             pushed: { value: "def" }, report: { value: "merged" } }.freeze

  def stub_train(observe)
    train = instance_double(Hecks::Adapters::GitTrain, carry: QUEUED, observe: observe)
    allow(Hecks::Adapters::GitTrain).to receive(:new).and_return(train)
    allow(Hecks::Adapters::GitLauncher).to receive(:new).and_return(double(refresh: { report: { value: "ok" } }))
    allow(Hecks::Adapters::DesktopAlert).to receive(:new).and_return(double(announce: { report: { value: "ok" } }))
    train
  end

  def send_train(command, **args) = @hecks.dispatch_flat("Hecks::SendTrain.#{command}", run: KEY, **args)

  def boarding = @hecks.query("Hecks::SendTrain.Outcome", run: KEY).first

  def board_and_watch
    @hecks = boot_hecks_in_memory
    send_train("Board", confirm: { value: true })
    send_train("Watch")
  end
end
