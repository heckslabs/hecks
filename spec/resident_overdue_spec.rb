require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"

# A resident stands for as long as a line it forked runs, so a stuck child keeps it up past its
# idle time (ADR 0201). It then says so in a note beside its socket, naming itself and the line,
# and removes the note when the line has ended. No process is forked: a parked thread stands in
# for the monitor of a running line.
RSpec.describe Hecks::Adapters::Driving::Resident::Overdue do
  let(:paths) { Hecks::Adapters::Driving::Resident::Paths }
  let(:server) { Hecks::Adapters::Driving::Resident::Server.new("/checkout", "/checkout/exe/hecks") }
  let(:note) { paths.overdue("/checkout") }

  around do |example|
    Dir.mktmpdir("hro") do |dir|
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = dir
      FileUtils.mkdir_p(paths.directory)
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
      @running&.kill
    end
  end

  before { server.instance_variable_set(:@settings, { idle_seconds: 600.0 }) }

  # A line the resident forked and still waits for.
  def running_line(argv = %w[tickets Work.undone area.value=x --wait])
    @running = Thread.new { Queue.new.pop }
    server.send(:label, @running, 47_817, argv)
    server.instance_variable_set(:@monitors, [@running])
  end

  def noted_after(seconds)
    server.send(:note_overdue, Time.now + seconds)
    File.exist?(note) ? File.read(note) : nil
  end

  it "says nothing while its line has run for less than the idle time" do
    running_line
    expect(noted_after(599)).to be_nil
  end

  it "names itself and the line once the line has outrun the idle time", :aggregate_failures do
    running_line
    text = noted_after(601)
    expect(text).to include("resident #{Process.pid}", "past its idle time of 600 seconds")
    expect(text).to include("pid 47817", "tickets Work.undone area.value=x")
  end

  it "shows only the first words of the line" do
    running_line
    expect(noted_after(601)).not_to include("--wait")
  end

  it "does not write the same note again" do
    running_line
    noted_after(601)
    allow(paths).to receive(:put)
    noted_after(700)
    expect(paths).not_to have_received(:put)
  end

  it "removes the note when the line has ended" do
    running_line
    noted_after(601)
    @running.kill.join
    expect(noted_after(700)).to be_nil
  end

  it "keeps the note while a retired resident waits for the line, and removes it after", :aggregate_failures do
    running_line
    waiting = Thread.new { server.send(:wait_for_lines) }
    @running.kill
    expect(waiting.join(5)).to be(waiting)
    expect(File.exist?(note)).to be(false)
  end
end
