require "spec_helper"
require "fileutils"
require "hecks/tools/gate_memo/session"
require "hecks/tools/gate_memo/ruby_files"
require "hecks/tools/gate_memo/rehearsal"
require "hecks/tools/gate_report"
require "hecks/tools/gate"

# The gate's memo: a check is skipped only when its inputs are the ones of its last green run, a red
# result is never reused, and a memo that cannot be read or written runs every check in full.
RSpec.describe "Hecks::Tools::GateMemo" do
  let(:root) { Dir.mktmpdir("gate-memo-root") }
  let(:memo_file) { File.join(Dir.mktmpdir("gate-memo-file"), "memo.json") }
  let(:check) { { "id" => "shape_ledger", "run" => %w[true] } }

  after { FileUtils.rm_rf([root, File.dirname(memo_file)]) }

  def write(rel, text)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def session = Hecks::Tools::GateMemo::Session.new(root: root, env: {}, file: memo_file)

  def ran_green(checks)
    run = session
    plan = run.plan(checks)
    run.record(plan.run.to_h { |c| [c["id"], ["", true]] })
    plan
  end

  def ran_red(checks)
    run = session
    plan = run.plan(checks)
    run.record(plan.run.to_h { |c| [c["id"], ["boom", false]] })
  end

  before { write("lib/a.rb", "A = 1\n") }

  it "runs a check the first time it is asked" do
    expect(session.plan([check]).run).to eq([check])
  end

  it "skips a check whose inputs are unchanged since its green run" do
    ran_green([check])
    expect(session.plan([check]).skipped.map { |c, _| c["id"] }).to eq(["shape_ledger"])
  end

  it "runs a check again when a file it reads changed" do
    ran_green([check])
    write("lib/a.rb", "A = 2\n")
    expect(session.plan([check]).run).to eq([check])
  end

  it "never reuses a red result" do
    ran_red([check])
    expect(session.plan([check]).run).to eq([check])
  end

  it "runs every check in full, and says so, when the memo cannot be read" do
    File.write(memo_file, "not json")
    plan = session.plan([check])
    expect(plan.notes.join).to include("unusable")
  end

  it "declares inputs for every check of the quick and pre-push stages" do
    stages = Hecks::Tools::Gate.stages.values_at("quick", "pre_push")
    ids = stages.flat_map { |stage| stage["checks"].map { |check| check["id"] } }
    expect(ids - Hecks::Tools::GateMemo::INPUTS.keys - ["rubocop"]).to eq([])
  end

  it "keeps an unreadable memo as it was rather than overwriting it" do
    File.write(memo_file, "not json")
    session.plan([check])
    session.record("shape_ledger" => ["", true])
    expect(File.read(memo_file)).to eq("not json")
  end

  it "says so when the memo cannot be written, and the check still ran" do
    bad = File.join(root, "lib/a.rb", "memo.json")
    run = Hecks::Tools::GateMemo::Session.new(root: root, env: {}, file: bad)
    run.plan([check])
    expect(run.record("shape_ledger" => ["", true])).to contain_exactly(/not written/)
  end

  describe "checkouts on different trees" do
    let(:other) { Dir.mktmpdir("gate-memo-other") }

    after { FileUtils.rm_rf(other) }

    before do
      FileUtils.mkdir_p(File.join(other, "lib"))
      File.write(File.join(other, "lib/a.rb"), "A = 2\n")
    end

    def at(dir) = Hecks::Tools::GateMemo::Session.new(root: dir, env: {}, file: memo_file)

    def green_at(dir)
      run = at(dir)
      run.record(run.plan([check]).run.to_h { |c| [c["id"], ["", true]] })
    end

    def red_at(dir)
      run = at(dir)
      run.record(run.plan([check]).run.to_h { |c| [c["id"], ["boom", false]] })
    end

    def skipped_at?(dir) = at(dir).plan([check]).skipped.any?

    it "each find their own green run, taking turns", :aggregate_failures do
      green_at(root)
      green_at(other)

      expect(skipped_at?(root)).to be(true)
      expect(skipped_at?(other)).to be(true)
    end

    # Both trees ran green; then the other tree changed and its run went red.
    def other_goes_red
      green_at(root)
      green_at(other)
      File.write(File.join(other, "lib/a.rb"), "A = 3\n")
      red_at(other)
    end

    it "are not evicted by a red result on another tree", :aggregate_failures do
      other_goes_red

      expect(skipped_at?(root)).to be(true)
      expect(skipped_at?(other)).to be(false)
    end

    it "forget the runs on the inputs a red result proved wrong" do
      memo = {}
      Hecks::Tools::GateMemo.remember(memo, "c", Hecks::Tools::GateMemo.green("one"))
      Hecks::Tools::GateMemo.remember(memo, "c", Hecks::Tools::GateMemo.green("two"))
      Hecks::Tools::GateMemo.forget(memo, "c", "two")

      expect(Hecks::Tools::GateMemo.runs(memo["c"]).map { |run| run["inputs"] }).to eq(["one"])
    end

    it "keep at most the newest four runs of a check" do
      memo = {}
      5.times { |n| Hecks::Tools::GateMemo.remember(memo, "c", Hecks::Tools::GateMemo.green("in#{n}")) }

      expect(Hecks::Tools::GateMemo.runs(memo["c"]).map { |run| run["inputs"] }).to eq(%w[in4 in3 in2 in1])
    end
  end

  describe "the memo file" do
    def keep_run(id, inputs) = ->(memo) { Hecks::Tools::GateMemo.remember(memo, id, Hecks::Tools::GateMemo.green(inputs)) }

    # The memo after a run recorded its result while another process recorded its own.
    def memo_after_concurrent_record
      run = session
      run.plan([check])
      Hecks::Tools::GateMemo.update(memo_file, &keep_run("other_check", "theirs"))
      run.record("shape_ledger" => ["", true])
      JSON.parse(File.read(memo_file))
    end

    it "keeps what another process recorded while a run was going" do
      expect(memo_after_concurrent_record.keys).to contain_exactly("other_check", "shape_ledger")
    end

    it "leaves no temp file behind and writes through a rename", :aggregate_failures do
      Hecks::Tools::GateMemo.update(memo_file, &keep_run("c", "x"))

      expect(Dir.children(File.dirname(memo_file)).sort).to eq(%w[memo.json memo.json.lock])
      expect(JSON.parse(File.read(memo_file)).keys).to eq(["c"])
    end

    it "reads a file caught half way through being written once its writer finishes" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(memo_file).and_return('{"a":', "{}")
      allow(Hecks::Tools::GateMemo).to receive(:sleep)
      File.write(memo_file, "x")

      expect(Hecks::Tools::GateMemo.read(memo_file)).to eq([{}, nil])
    end

    it "does not overwrite an unreadable file when it updates" do
      File.write(memo_file, "not json")

      expect(Hecks::Tools::GateMemo.update(memo_file, &keep_run("c", "x"))).to match(/memo.json/)
    end
  end

  it "prints a skipped check as skipped, never as passed" do
    plan = Hecks::Tools::GateMemo::Session::Plan.new([], [[check, "then"]], [])
    expect { Hecks::Tools::GateReport.report("quick", plan, {}) }
      .to output(/shape_ledger: unchanged, skipped/).to_stdout
  end

  # RuboCop reuses per file: skipped when every Ruby file matches the green run, incremental when
  # the changed files and their requirers are the only ones to lint, and full when that cannot be
  # known.
  describe "RubyFiles" do
    let(:root) { Dir.mktmpdir("gate-memo-ruby") }
    let(:ruby) { Hecks::Tools::GateMemo::RubyFiles }

    def write(rel, text)
      path = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    def green_entry
      { "inputs" => ruby.config(root), "files" => ruby.hashes(root) }
    end

    before do
      write("lib/a.rb", "A = 1\n")
      write("lib/b.rb", "require_relative \"a\"\n")
      write("lib/c.rb", "C = 1\n")
    end

    it "skips RuboCop when the Ruby files and their hashes match the green run" do
      expect(ruby.plan(root, green_entry, ruby.hashes(root)).first).to eq(:skip)
    end

    it "leaves an excluded file out of an incremental run, and still lints the rest" do
      write(".rubocop.yml", "AllCops:\n  Exclude:\n    - \"**/lib/b.rb\"\n")
      write("lib/d.rb", "require_relative \"a\"\n")
      entry = green_entry
      write("lib/a.rb", "A = 2\n")
      expect(ruby.plan(root, entry, ruby.hashes(root))[1]).to eq(%w[lib/a.rb lib/d.rb])
    end

    it "lints a changed file and the file that requires it" do
      entry = green_entry
      write("lib/a.rb", "A = 2\n")
      mode, files = ruby.plan(root, entry, ruby.hashes(root))
      expect([mode, files]).to eq([:incremental, %w[lib/a.rb lib/b.rb]])
    end

    it "runs RuboCop in full when there is no green run to compare with" do
      expect(ruby.plan(root, nil, ruby.hashes(root)).first).to eq(:full)
    end

    it "runs RuboCop in full when the configuration changed" do
      entry = green_entry
      write(".rubocop.yml", "AllCops: {}\n")
      expect(ruby.plan(root, entry, ruby.hashes(root)).first).to eq(:full)
    end
  end

  # A mint rehearsal's copy is reused only for the watermark and edge it read, and only after
  # a would_mint.
  describe "Rehearsal" do
    let(:rehearsal) { Hecks::Tools::GateMemo::Rehearsal }
    let(:memo_hash) { {} }

    def remember(verdict, watermark: 4, edge: "e1")
      rehearsal.remember(memo_hash, "ledger", rehearsal.entry(verdict: verdict, watermark: watermark, edge: edge))
    end

    it "reuses a would_mint rehearsal on the same watermark and edge" do
      remember("would_mint")
      expect(rehearsal.reusable?(memo_hash, "ledger", watermark: 4, edge: "e1")).to be(true)
    end

    it "does not reuse a rehearsal once the watermark moved" do
      remember("would_mint")
      expect(rehearsal.reusable?(memo_hash, "ledger", watermark: 5, edge: "e1")).to be(false)
    end

    it "does not reuse a rehearsal once the edge changed" do
      remember("would_mint")
      expect(rehearsal.reusable?(memo_hash, "ledger", watermark: 4, edge: "e2")).to be(false)
    end

    it "keeps no copy for a verdict other than would_mint" do
      remember("would_refuse")
      expect(memo_hash).to be_empty
    end

    it "refuses a reused rehearsal whose watermark the live ledger no longer holds" do
      entry = rehearsal.entry(verdict: "would_mint", watermark: 4, edge: "e1")
      expect(rehearsal.moved?(entry, 5)).to be(true)
    end
  end
end
