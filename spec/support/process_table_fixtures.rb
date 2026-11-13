require "hecks/hecks/adapters/machine_sampling/process_classes"

# A process table that stands in for `ps`: a claude daemon whose log names one claimed spare host,
# the session's shell under that host, and twenty-four `yes` processes under the shell.
module ProcessTableFixtures
  Entry = Hecks::Adapters::MachineSampling::ProcessClasses::Entry

  # @return [Array<Entry>] the daemon, a claimed host, its session, its shell and the runaways
  def runaway_table
    [Entry.new(10, 1, 0.1, "/bin/claude daemon run --json-path /x/daemon.json --log-file /x/daemon.log"),
     Entry.new(20, 10, 0.2, "claude bg-pty-host --bg-pty-host /tmp/spare/ab.pty.sock"),
     Entry.new(30, 20, 3.0, "claude bg-spare --bg-spare /tmp/spare/ab.claim.sock"),
     Entry.new(87_255, 30, 0.0, "/bin/zsh -c run-the-repro"),
     Entry.new(99, 1, 5.0, "/usr/sbin/mds_stores")] + runaways
  end

  def runaways = (1..24).map { |n| Entry.new(1000 + n, 87_255, 43.0, "yes") }

  # @return [#call] the daemon log's claims: host 20 was claimed by session s1
  def claims_of_s1 = ->(log) { log == "/x/daemon.log" ? { 20 => "s1" } : {} }

  # @param table [Array<Entry>] the stand-in table
  # @return [Hecks::Adapters::MachineSampling::ProcessClasses] the reader over it
  def process_classes(table = runaway_table)
    Hecks::Adapters::MachineSampling::ProcessClasses.new(entries: -> { table }, claims: claims_of_s1)
  end
end
