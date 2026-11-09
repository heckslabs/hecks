# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require "tmpdir"
require "timeout"

# How the live store opens: a failed boot is remembered, a slow one is not ended by a reader's
# deadline, and a changed declaration boots the domain again while the old runtime serves.
RSpec.describe Hecks::Adapters::PipelineBoard::LiveStore do
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }
  let(:time) { [0.0] }
  let(:boots) { [] }
  let(:root) { Dir.mktmpdir("live") }

  after { FileUtils.rm_rf(root) }

  def runtime(rows = %i[a b])
    aggregate = Struct.new(:hecks_name).new("AgentRun")
    bluebook = Struct.new(:aggregates).new([aggregate])
    registry = Class.new do
      define_method(:bluebook) { |_domain| bluebook }
      define_method(:repository) { |_domain, _aggregate| Struct.new(:all).new(rows) }
    end.new
    Struct.new(:registry).new(registry)
  end

  def store(booter, **timing)
    described_class.new(root: root, booter: booter, clock: -> { time.first },
                        timing: { retry: 60, check: 0, wait: 2 }.merge(timing))
  end

  def failing
    lambda do |_|
      boots << :try
      raise "syntax error"
    end
  end

  def gated(gate) = store(->(_) { gate.pop && runtime }, wait: 0.05)

  def attempt(reader)
    reader.records("Hecks", "AgentRun")
  rescue unavailable => e
    e.message
  end

  # Reads until the store answers `expected`, moving the clock past the cache window each time.
  def eventually(reader, expected)
    Timeout.timeout(5) { Thread.pass until (time[0] += 10) && attempt(reader) == expected }
    attempt(reader)
  end

  def declaration = File.join(root, "lib/hecks/hecks/hecks.bluebook")

  # A store over a declaration file, whose first boot holds `old` and later ones `new`, and
  # whose later boots wait for the gate when one is given.
  def store_over_declaration(gate = nil)
    FileUtils.mkdir_p(File.dirname(declaration))
    File.write(declaration, "one")
    store(lambda do |_|
      nth = boots.push(1).size
      gate&.pop if nth > 1
      runtime(nth == 1 ? %i[old] : %i[new])
    end)
  end

  def edit_after_first_read(reader)
    attempt(reader)
    File.write(declaration, "two, longer")
    time[0] += 10
  end

  # A store whose second boot (the first reload) fails and whose later ones succeed.
  def store_with_failing_reload
    FileUtils.mkdir_p(File.dirname(declaration))
    File.write(declaration, "one")
    store(lambda do |_|
      nth = boots.push(1).size
      raise "reload broke" if nth == 2

      runtime(nth == 1 ? %i[old] : %i[new])
    end)
  end

  def wait_for_problem(reader)
    Timeout.timeout(5) { Thread.pass until reader.problem }
  end

  def wait_for_boots(count)
    Timeout.timeout(5) { Thread.pass until boots.size >= count }
  end

  describe "a reload that fails" do
    let(:reader) { store_with_failing_reload }

    before do
      edit_after_first_read(reader)
      attempt(reader)
      wait_for_problem(reader)
    end

    it "leaves the old runtime serving", :aggregate_failures do
      expect(attempt(reader)).to eq(%i[old])
      expect(reader.problem).to include("reload broke")
    end

    it "is not tried again within the retry window" do
      time[0] += 10
      attempt(reader)

      expect(boots.size).to eq(2)
    end

    it "is tried again after the retry window, and the new runtime serves" do
      time[0] += 70
      attempt(reader)
      wait_for_boots(3)

      expect(eventually(reader, %i[new])).to eq(%i[new])
    end

    it "stops reporting a problem once a reload succeeds" do
      time[0] += 70
      attempt(reader)
      wait_for_boots(3)
      eventually(reader, %i[new])

      expect(reader.problem).to be_nil
    end
  end

  def port = File.join(root, "lib/hecks/ports/clock.port")

  def write_declarations
    FileUtils.mkdir_p([File.dirname(port), File.dirname(declaration)])
    [declaration, port].each { |file| File.write(file, "one") }
  end

  def edit_port
    File.write(port, "two, longer")
    time[0] += 10
  end

  # A store over a domain declaration and one shared port, read once, then the port edited.
  def store_with_edited_port
    write_declarations
    reader = store(->(_) { runtime(boots.push(1).size == 1 ? %i[old] : %i[new]) })
    attempt(reader)
    edit_port
    reader
  end

  it "boots again when a shared port declaration changes" do
    expect(eventually(store_with_edited_port, %i[new])).to eq(%i[new])
  end

  it "does not boot again within the retry window after a failure" do
    broken = store(failing)
    3.times { attempt(broken) }
    expect(boots.size).to eq(1)
  end

  it "says why it did not open" do
    expect(attempt(store(failing))).to include("did not open: syntax error")
  end

  it "tries again after the retry window" do
    broken = store(failing)
    attempt(broken)
    time[0] += 61
    attempt(broken)
    expect(boots.size).to eq(2)
  end

  it "says it is still opening while a slow boot goes on" do
    gate = Queue.new
    message = attempt(gated(gate))
    gate << :go
    expect(message).to include("still opening")
  end

  it "finishes a slow boot a reader gave up on" do
    gate = Queue.new
    slow = gated(gate)
    attempt(slow)
    gate << :go
    expect(eventually(slow, %i[a b])).to eq(%i[a b])
  end

  it "boots the domain again when a declaration file changes" do
    reader = store_over_declaration
    edit_after_first_read(reader)
    expect(eventually(reader, %i[new])).to eq(%i[new])
  end

  it "serves the old runtime until the new one is ready" do
    gate = Queue.new
    reader = store_over_declaration(gate)
    edit_after_first_read(reader)
    expect(attempt(reader)).to eq(%i[old]).and(satisfy { gate << :go })
  end
end
