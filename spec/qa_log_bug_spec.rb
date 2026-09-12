require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_ledger_fixture"

# `bin/qa_log_bug`, PROVEN AGAINST THE REAL THING — a real subprocess, a
# real disposable PostgresEra ledger (`spec/support/qa_ledger_fixture.rb`,
# and `spec/qa_sweep_all_spec.rb`'s own header for why nothing here can
# be proven against Memory). The three claims the script exists for: a
# passing demonstration is refused and logs nothing; a failing one is
# logged with the disposition given; and the minted `BUG#` skips every
# number and every reference already on file.
RSpec.describe "bin/qa_log_bug", :io do
  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @ledger = QaLedgerFixture::Ledger.new(database: "hecks_qa_log_bug_spec").stand_up!
  end

  after(:all) { @ledger&.tear_down! }
  before { @ledger.reset! }

  def a_sweep_on_file
    @ledger.boot
    target = QualityControl::Target.identify!(reference: { value: "banking" }, path: { value: "examples/banking" })
    QualityControl::Sweep.open!(target: target.id, reference: { value: "SW-1" }, engineer: { value: "qa_sweep" })
  end

  def log_bug(demonstration, *extra)
    @ledger.run("qa_log_bug", "--sweep", "SW-1", "--title", "as: is accepted and does nothing",
                "--demonstration", demonstration, "--symptom", "accepted silently", "--expectation", "refused",
                "--submitter", "Claude QA", *extra)
  end

  def bugs_on_file
    @ledger.boot.query("QualityControl::Bug.All")
           .map { |row| [row[:reference][:value], row[:sequence][:value], row[:disposition][:value]] }
  end

  it "refuses a demonstration that passes, and logs nothing" do
    a_sweep_on_file

    stdout, stderr, status = log_bug("exit 0", "--triage", "self_contained")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("the demonstration PASSED")
    expect(stdout).not_to include("logged BUG#")
    expect(bugs_on_file).to be_empty
  end

  it "logs a bug whose demonstration fails, already triaged" do
    a_sweep_on_file

    stdout, _stderr, status = log_bug("echo 'expected refusal, got acceptance'; exit 3", "--triage", "bigger")

    expect(status.exitstatus).to eq(0), stdout
    expect(stdout).to include("demonstration failed as required (exit 3)", "expected refusal, got acceptance",
                              "logged BUG#1 (sequence 1, bigger) against SW-1")
    expect(bugs_on_file).to eq([["BUG#1", 1, "bigger"]])
  end

  # A REAL BUG#21 WAS ASSIGNED TWICE once — this is the mint that cannot
  # do that: past the highest sequence on file, AND past any reference a
  # hand-typed `log` already took out of order.
  it "mints past every sequence and every reference already on file" do
    sweep = a_sweep_on_file
    %w[BUG#1 BUG#4].each_with_index do |reference, index|
      QualityControl::Bug.log!(sweep: sweep.id, reference: { value: reference }, sequence: { value: index + 2 },
                               title: { value: "t" }, demonstration: { value: "d" }, symptom: { value: "s" },
                               expectation: { value: "e" }, submitter: { value: "x" })
    end

    stdout, _stderr, status = log_bug("exit 1", "--triage", "self_contained")

    expect(status.exitstatus).to eq(0), stdout
    # sequences on file: 2, 3 → next is 4; "BUG#4" is taken → walks to 5,
    # reference and sequence in lockstep (the reference IS the sequence).
    expect(stdout).to include("logged BUG#5 (sequence 5, self_contained)")
    expect(bugs_on_file.map(&:first)).to contain_exactly("BUG#1", "BUG#4", "BUG#5")
  end

  it "refuses without a triage, and without a sweep it can find" do
    a_sweep_on_file

    _stdout, stderr, status = log_bug("exit 1")
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("--triage is required")

    _stdout, stderr, status = @ledger.run("qa_log_bug", "--sweep", "SW-nope", "--title", "t", "--demonstration", "exit 1",
                                          "--symptom", "s", "--expectation", "e", "--submitter", "x", "--triage", "bigger")
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("no such sweep")
    expect(bugs_on_file).to be_empty
  end
end
