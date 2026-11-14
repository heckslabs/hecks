# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "hecks/pipeline_board/adapters/pipeline_web"

# A run of journal lines costs one read, not one per line: the train tile shares the git answers,
# the journal shares a read of the persisted stores, and a stream tells a moved state by its
# version. Measured on 2026-11-13, these three were most of what the board cost a busy machine.
RSpec.describe "the board's reads on a run of journal lines" do
  let(:base) { Dir.mktmpdir("board-reads") }
  let(:asked) { [] }
  let(:wakes) { Queue.new }
  let(:sent) { Queue.new }

  after { FileUtils.rm_rf(base) }

  def git
    program = ->(_dir, *args) { asked.push(args.first) && "abc1234 2026-11-13T12:00:00Z" }
    Hecks::Adapters::PipelineGit.new(root: base, settings: { git: program, train: base })
  end

  def journal(**settings)
    trace = ->(count, event) { asked.push([count, event]) && { events: [] } }
    held = { trace: trace, tap: File.join(base, "events.jsonl") }.merge(settings)
    Hecks::Adapters::PipelineJournal.new(root: base, settings: held)
  end

  def hub = Struct.new(:join, :current) { def leave(_queue) = nil }.new(wakes, [])

  # A stream handed one state per look. Each look leaves one wake, so the stream looks again
  # until the states run out.
  def stream_over(states)
    board = Hecks::Adapters::PipelineBoard
    looked = -> { wakes.push(board::Hub::Wake.new(1, [], false)) && (states.shift || throw(:done)) }
    board::Stream.new(hub: hub, state: looked)
  end

  # The states a stream sends over those looks.
  def states_sent(states)
    stream = stream_over(states)
    catch(:done) { stream.each { |event| sent << event[:state] if event.key?(:state) } }
    Array.new(sent.size) { sent.pop }
  end

  def standing(version, **rest) = { version: version, stale: false, refresh_error: nil }.merge(rest)

  it "draws the train tile twice from one read of git" do
    reader = git
    2.times { reader.train }
    expect(asked.count("log")).to eq(1)
  end

  it "has no way to read past the kept git answers" do
    expect(git).not_to respond_to(:train_now)
  end

  it "reads the persisted stores once for a run of journal lines" do
    reader = journal
    3.times { reader.named("WorkFinished", 200) }
    expect(asked).to eq([[200, "WorkFinished"]])
  end

  it "reads the stores again when a spec keeps nothing" do
    reader = journal(ttl: 0)
    2.times { reader.named("WorkFinished", 200) }
    expect(asked.size).to eq(2)
  end

  it "sends a state once while its version stands, whatever else it holds" do
    expect(states_sent([standing(1, rows: [1]), standing(1, rows: [2])]).size).to eq(1)
  end

  it "sends the state again when its version moves" do
    expect(states_sent([standing(1), standing(2)]).map { |state| state[:version] }).to eq([1, 2])
  end

  it "digests a state that carries no version, as before" do
    expect(states_sent([{ rows: [1] }, { rows: [2] }]).size).to eq(2)
  end

  it "keeps git, gh and the stores longer than a read period, as the bluebook's settings say" do
    kept = Hecks::Adapters::PipelineBoard::Rules.settings("git_keep_seconds", "github_keep_seconds", "stores_keep_seconds")
    expect(kept).to eq(git_keep_seconds: 60, github_keep_seconds: 120, stores_keep_seconds: 300)
  end

  it "shares one read of the stores between the feed and the landed times" do
    File.write(File.join(base, "events.jsonl"), "#{JSON.generate(kind: "event", at: "t", aggregate: "A", id: "1", event: "E")}\n")
    reader = journal
    reader.landed_times
    reader.recent(40)
    expect(asked).to eq([[200, nil]])
  end

  it "takes a reader's keeping from its setting when the reader names none" do
    cache = Hecks::Adapters::PipelineBoard::Cache.kept({}, "git_keep_seconds")
    expect(Array.new(2) { cache.fetch(:asked) { asked.push(1).size } }).to eq([1, 1])
  end

  # A wiring reader over a source that counts its looks at the bluebook files.
  def wiring(**settings)
    source = Struct.new(:asked) { def stamp = asked.push(1) && :same }.new(asked)
    registry = Hecks::Runtime::Registry.new(root: base)
    Hecks::Adapters::PipelineWiring.new(registry: registry, settings: { source: source }.merge(settings))
  end

  it "looks at the bluebook files once for a run of wiring questions" do
    reader = wiring(look_seconds: 3600)
    looks = asked.size
    5.times { reader.digest }
    expect(asked.size - looks).to eq(1)
  end

  it "looks on every question when a spec asks for no gap" do
    reader = wiring(look_seconds: 0)
    looks = asked.size
    3.times { reader.digest }
    expect(asked.size - looks).to eq(3)
  end

  it "finds a linked worktree's main checkout from its .git file, with no git" do
    File.write(File.join(base, ".git"), "gitdir: /somewhere/main/.git/worktrees/branch\n")
    expect(Hecks::Adapters::PipelineBoard::OwnerRoot.of(base)).to eq("/somewhere/main")
  end
end
