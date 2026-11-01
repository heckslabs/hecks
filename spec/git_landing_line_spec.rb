require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"

# The landing line: tickets taken in order, a wait that wakes by lock rather than by polling, a
# heartbeat that keeps a slow holder in place, and the shell lock honoured while it stands.
RSpec.describe Hecks::Adapters::GitLanding::Lineup do
  let(:dir) { Dir.mktmpdir("hecks-landing-line") }
  let(:said) { Queue.new }
  let(:order) { Queue.new }
  let(:offset) { [0] }
  let(:clock) { -> { Time.now + offset.first } }

  after { FileUtils.remove_entry(dir) }

  def lineup(**tune)
    described_class.new(dir, locks: [], say: ->(text) { said << text }, heartbeat: 0.05, clock: clock, **tune)
  end

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def holder
    line.join("work/front", ready: true).tap { |front| line.promote(front) }
  end

  def shell_lock
    File.join(dir, "land.lock").tap { |lock| Dir.mkdir(lock) }
  end

  def old_claim
    held = JSON.generate(token: "old", branch: "work/old", at: Time.now.to_f)
    File.join(dir, "hecks-landing.claim").tap { |claim| File.write(claim, held) }
  end

  def line = Hecks::Adapters::GitLanding::Line.new(dir, clock: clock, heartbeat: 0.05)

  def land(name, **tune)
    Thread.new do
      Thread.current.report_on_exception = false
      lineup(**tune).stand(name, onto: "main", checkout: dir) { |note| (order << name) && note }
    end
  end

  def heard(text)
    Timeout.timeout(5) { loop { break if said.pop.include?(text) } }
  end

  def landed = Array.new(order.size) { order.pop }

  def waiters(*names)
    names.each_with_index.map { |name, index| land(name).tap { heard("#{%w[2nd 3rd 4th][index]} in line") } }
  end

  def beating(ticket)
    Timeout.timeout(5) { Queue.new.pop(timeout: 0.05) until File.mtime(ticket.path) > Time.now + (offset.first / 2) }
  end

  it "lands three waiters in the order they joined", :aggregate_failures do
    front = line.join("work/front", ready: true)
    threads = waiters("work/a", "work/b", "work/c")
    line.leave(front)
    threads.each(&:join)
    expect(landed).to eq(%w[work/a work/b work/c])
  end

  it "says its place and the holder while it waits", :aggregate_failures do
    front = holder
    thread = land("work/a")

    expect(Timeout.timeout(5) { said.pop }).to eq("work/a is 2nd in line; holder work/front has landed for 0 minutes")
    line.leave(front)
    expect(thread.value).to match(%r{2nd in line; holder work/front has landed for 0 minutes; waited \d+s})
  end

  it "does not supersede a slow holder whose heartbeat is fresh", :aggregate_failures do
    front = line.join("work/slow", ready: true)
    offset[0] = 45 * 60
    beating(front)

    expect { land("work/a", wait_minutes: 0.03).value }.to raise_error(failure, %r{waited .* behind work/slow})
    expect(Dir.glob(File.join(dir, "hecks-landing", "queue", "*.ticket")).size).to eq(1)
  end

  it "supersedes a holder whose process is gone", :aggregate_failures do
    line.join("work/crashed", ready: true).close
    thread = land("work/b")

    expect(thread.value).to include("superseded the abandoned landing of work/crashed")
    expect(landed).to eq(["work/b"])
  end

  it "keeps the waiters in order when the holder dies", :aggregate_failures do
    front = line.join("work/crashed", ready: true)
    threads = waiters("work/b", "work/c")
    front.close

    threads.each(&:join)
    expect(landed).to eq(%w[work/b work/c])
  end

  it "supersedes a holder that stopped beating while its process lives" do
    front = line.join("work/hung", ready: true)
    front.instance_variable_get(:@beater).kill
    offset[0] = 45 * 60

    expect(land("work/a").value).to include("no heartbeat for 45 minutes")
  end

  it "waits behind an existing shell lock until it is gone", :aggregate_failures do
    lock = shell_lock
    thread = land("work/a", locks: [lock], mine: ->(_) { false })
    heard("waiting for the shell lock")

    expect([Dir.rmdir(lock), thread.join, landed].last).to eq(["work/a"])
  end

  it "does not wait behind a shell lock its own caller made" do
    lock = shell_lock

    expect(land("work/a", locks: [lock], mine: ->(_) { true }).value).to be_nil
  end

  it "waits behind a fresh claim written by an older build" do
    claim = old_claim
    thread = land("work/a")
    heard("work/old, landing by an older build")
    File.delete(claim)

    expect(thread.value).to be_nil
  end
end
