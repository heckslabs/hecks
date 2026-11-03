require "spec_helper"
require "fileutils"
require "open3"
require "hecks/tools/gate_memo/session"
require "hecks/tools/gate_memo/standalone"
require "hecks/hecks/adapters/codebase/regeneration"

# What the gate's memo hashes: an unchanged tree skips every memoised check, a file outside a
# check's inputs leaves it skipped, a file inside reruns it, and a stale memo never hides a change.
RSpec.describe "Hecks::Tools::GateMemo inputs" do
  # rubocop:disable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength
  let(:memo) { Hecks::Tools::GateMemo }
  let(:root) { Dir.mktmpdir("gate-memo-inputs") }
  let(:memo_file) { File.join(Dir.mktmpdir("gate-memo-inputs-file"), "memo.json") }
  let(:memoised) { memo::INPUTS.keys }
  let(:checks) { memoised.map { |id| { "id" => id, "run" => %w[true] } } }

  after { FileUtils.rm_rf([root, File.dirname(memo_file)]) }

  def write(rel, text)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def ran_green
    run = memo::Session.new(root: root, env: {}, file: memo_file)
    plan = run.plan(checks)
    run.record(plan.run.to_h { |c| [c["id"], ["", true]] })
    plan.run.map { |c| c["id"] }
  end

  before do
    %w[lib/a.rb spec/a_spec.rb examples/e/e.bluebook rust/src/generated/g.rs docs/implemented/reference/r.md
       docs/notes.md .github/workflows/ci.yml].each { |rel| write(rel, "one\n") }
    ran_green
  end

  it "reads each check's globs from the inputs of its GateCheck row" do
    declared = Hecks::Vocabulary.rows("GateCheck").select { |row| row["inputs"].to_s.split.any? }.map { |row| row["id"] }

    expect(memo::INPUTS.keys).to match_array(declared.uniq)
  end

  it "skips every memoised check on an unchanged tree" do
    expect(ran_green).to eq([])
  end

  it "reruns fuzzing, doc coverage and codegen drift when the library changes" do
    write("lib/a.rb", "two\n")
    expect(ran_green).to include("fuzzing", "doc_coverage", "codegen_drift")
  end

  it "leaves fuzzing, doc coverage and codegen drift skipped when only a doc outside the reference changes" do
    write("docs/notes.md", "two\n")
    expect(ran_green & %w[fuzzing doc_coverage codegen_drift]).to eq([])
  end

  it "leaves them skipped when only a workflow changes" do
    write(".github/workflows/ci.yml", "two\n")
    expect(ran_green & %w[fuzzing doc_coverage codegen_drift]).to eq([])
  end

  it "reruns doc coverage, and only it of the three, when a reference page changes" do
    write("docs/implemented/reference/r.md", "two\n")
    expect(ran_green & %w[fuzzing doc_coverage codegen_drift]).to eq(["doc_coverage"])
  end

  it "reruns codegen drift, but not doc coverage, when the committed generated output changes" do
    write("rust/src/generated/g.rs", "two\n")
    again = ran_green
    expect(again).to include("codegen_drift")
    expect(again).not_to include("doc_coverage")
  end

  it "reruns a check whose input is edited, so a stale memo never hides a change" do
    write("spec/a_spec.rb", "two\n")
    expect(ran_green).to include("fuzzing")
    expect(ran_green).to eq([])
  end

  it "reruns fuzzing, the code generator and the whole-tree checks when a file under qa/ changes" do
    write("qa/settings.yml", "one\n")
    ran_green
    write("qa/settings.yml", "two\n")
    expect(ran_green).to include("fuzzing", "rspec", "codegen_drift")
  end

  it "leaves doc coverage and the style checks skipped when a file under qa/ changes" do
    write("qa/settings.yml", "one\n")
    ran_green
    write("qa/settings.yml", "two\n")
    expect(ran_green & %w[doc_coverage comment_style rust_fmt]).to eq([])
  end

  describe "in a git checkout" do
    before do
      write(".gitignore", "data/\n")
      write("examples/e/data/run.db", "one\n")
      _, status = Open3.capture2("git", "-C", root, "init", "-q")
      raise "git init failed" unless status.success?

      ran_green
    end

    it "does not read a file git ignores, which a run rewrites" do
      write("examples/e/data/run.db", "two\n")
      expect(ran_green).to eq([])
    end

    it "reads a file git would add" do
      write("examples/e/new.bluebook", "two\n")
      expect(ran_green).to include("codegen_drift", "fuzzing")
    end
  end

  describe "Standalone" do
    let(:standalone) { memo::Standalone }

    def guarded(id = "shape_ledger", &block) = standalone.guard(root, id, file: memo_file, &block)

    it "runs a check the first time and skips it on the same files, saying so" do
      write("lib/a.rb", "two\n")
      calls = 0
      first = guarded { (calls += 1) && "ok" }
      second = guarded { (calls += 1) && "ok" }
      expect([first, calls]).to eq(["ok", 1])
      expect(second).to match(/\Askipped as unchanged since \d{4}-\d\d-\d\dT/)
    end

    it "skips when the gate has just passed the check on the same files" do
      expect(guarded { raise "must not run" }).to start_with("skipped as unchanged since")
    end

    it "runs again once a file the check reads changes" do
      guarded { "ok" }
      write("lib/a.rb", "two\n")
      expect(guarded { "reran" }).to eq("reran")
    end

    it "does not skip for a file outside the check's inputs" do
      guarded { "ok" }
      write("docs/notes.md", "two\n")
      expect(guarded { "reran" }).to start_with("skipped")
    end

    it "keeps no pass for a check that raised" do
      write("lib/a.rb", "two\n")
      expect { guarded { raise "red" } }.to raise_error("red")
      expect(guarded { "reran" }).to eq("reran")
    end

    it "does not hide a red check behind a pass kept for older files" do
      guarded { "ok" }
      write("lib/a.rb", "broken\n")
      expect { guarded { raise "red" } }.to raise_error("red")
    end

    it "runs when the memo cannot be read" do
      File.write(memo_file, "[1]")
      expect(guarded { "ran" }).to eq("ran")
    end
  end

  describe "regenerate_corpus check" do
    let(:regeneration) { Hecks::Adapters::Codebase::Regeneration }
    let(:tree) { Struct.new(:root).new(root) }

    before do
      ENV["HECKS_GATE_MEMO"] = memo_file
      write("lib/a.rb", "two\n")
      allow(regeneration).to receive(:regenerate).and_return("checked")
    end

    after { ENV.delete("HECKS_GATE_MEMO") }

    def call(held) = regeneration.regenerate_remembered(nil, tree, held, held[:check] == true)

    it "skips an unchanged tree after a pass, and says so" do
      call({ check: true })
      expect(call({ check: true })).to start_with("skipped as unchanged since")
      expect(regeneration).to have_received(:regenerate).once
    end

    it "never skips a confirm run" do
      call({ check: true })
      call({ confirm: true })
      call({ confirm: true })
      expect(regeneration).to have_received(:regenerate).exactly(3).times
    end

    it "never skips a run of some domains" do
      call({ check: true })
      call({ check: true, domains: "pizzas" })
      expect(regeneration).to have_received(:regenerate).twice
    end

    it "runs again after a generator, bluebook or generated file changes" do
      call({ check: true })
      write("examples/e/e.bluebook", "two\n")
      call({ check: true })
      expect(regeneration).to have_received(:regenerate).twice
    end
  end
  # rubocop:enable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength

  describe "a gitignored local world" do
    before do
      write(".gitignore", "*.local.world\n")
      write("lib/hecks/hecks/hecks.local.world", "one\n")
      _, status = Open3.capture2("git", "-C", root, "init", "-q")
      raise "git init failed" unless status.success?

      ran_green
    end

    it "reruns the checks that boot the domain when it is edited" do
      write("lib/hecks/hecks/hecks.local.world", "two\n")
      expect(ran_green & %w[rspec fuzzing model_check query_agreement engine_agreement]).to have_attributes(size: 5)
    end

    it "leaves the checks that do not boot the domain skipped" do
      write("lib/hecks/hecks/hecks.local.world", "two\n")
      expect(ran_green & %w[comment_style doc_coverage rust_fmt shape_ledger]).to eq([])
    end

    it "reruns the checks that boot the domain when it is removed" do
      FileUtils.rm(File.join(root, "lib/hecks/hecks/hecks.local.world"))
      expect(ran_green).to include("fuzzing", "rspec", "model_check")
    end
  end
end
