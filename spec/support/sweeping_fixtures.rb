require "tmpdir"
require "json"
require "hecks/agents/adapters/sweeping"

module SweepingFixtures
  Reading = Struct.new(:out, :err, :ok) do
    def ok? = ok
  end

  HOSTS = [100, 200, 300, 400].freeze
  PS_LINE = "%<pid>d 1 10:00 90000 claude bg-pty-host --bg-pty-host /tmp/cc/spare/%<pid>d.pty.sock 200 50 -- x".freeze
  MEMORY = { "vm_stat" => "page size of 16384 bytes\nPages occupied by compressor: 64.",
             "sysctl"  => "total = 1000.00M  used = 250.00M" }.freeze

  def stamp(seconds_ago) = (Time.now.utc - seconds_ago).strftime("%Y-%m-%dT%H:%M:%S.000Z")

  def spawned(pid, ago) = "[#{stamp(ago)}] [bg] bg spare spawned host pid=#{pid}"

  def claimed(session) = "[#{stamp(1)}] [bg] bg claimed-spare #{session} (shell)"

  def log(*lines) = File.write(File.join(dir, "daemon.log"), lines.join("\n") << "\n")

  def traced_log = log(spawned(100, 600), claimed("aaaaaaaa"), spawned(200, 600), claimed("bbbbbbbb"), spawned(300, 600))

  def fake_shell(listed: [])
    outputs = MEMORY.merge("ps"     => HOSTS.map { |pid| format(PS_LINE, pid: pid) }.join("\n"),
                           "claude" => JSON.generate(listed.map { |id| { "id" => id } }))
    instance_double(Hecks::Adapters::Shell).tap do |shell|
      allow(shell).to receive(:capture) { |program, *| Reading.new(outputs.fetch(program, ""), "", true) }
    end
  end

  def adapter(shell = fake_shell)
    Hecks::Adapters::Sweeping.new(settings: { shell: shell, log: File.join(dir, "daemon.log"), projects: dir,
                                              tmp: dir, killer: ->(pid) { killed << pid } })
  end
end

RSpec.shared_context "with a sweep fixture" do
  include SweepingFixtures

  let(:dir)    { Dir.mktmpdir }
  let(:killed) { [] }

  after { FileUtils.remove_entry(dir) }
end
