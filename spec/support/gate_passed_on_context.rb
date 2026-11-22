# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "hecks/tools/gate_memo/session"
require "hecks/tools/gate_report"

# A temporary git checkout, a memo file and the helpers that run a gate session over them.
RSpec.shared_context "a checkout with a gate memo" do
  let(:root) { Dir.mktmpdir("gate-passed-root") }
  let(:memo_file) { File.join(Dir.mktmpdir("gate-passed-file"), "memo.json") }
  let(:shape) { { "id" => "shape_ledger", "run" => %w[true] } }
  let(:fmt) { { "id" => "rust_fmt", "run" => %w[true] } }

  after { FileUtils.rm_rf([root, File.dirname(memo_file)]) }

  before do
    git("init", "-q")
    write("lib/a.rb", "A = 1\n")
    write("rust/a.rs", "fn a() {}\n")
    write("Gemfile.lock", "lock 1\n")
  end

  def write(rel, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
    File.write(File.join(root, rel), text)
  end

  def git(*args) = Open3.capture2e("git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", *args)

  def commit_all
    git("add", ".")
    git("commit", "-q", "-m", "x")
    git("rev-parse", "--short=7", "HEAD").first.strip
  end

  def session = Hecks::Tools::GateMemo::Session.new(root: root, env: {}, file: memo_file)

  def pass(checks)
    run = session
    plan = run.plan(checks)
    run.record(plan.run.to_h { |c| [c["id"], ["", true]] })
    plan
  end

  def report_of(plan)
    out = StringIO.new
    $stdout = out
    Hecks::Tools::GateReport.report("quick", plan, {})
    out.string
  ensure
    $stdout = STDOUT
  end
end
