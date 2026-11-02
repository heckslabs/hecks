require "hecks"
require "tmpdir"
require "hecks/ports/persistence/plugins/era"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/desktop_alert"
require "hecks/hecks/adapters/git_launcher"
require_relative "support/postgres_probe"
require_relative "support/scratch_postgres"
require_relative "support/fenced_owner"
require_relative "support/push_train_depot"

# One boarding of the push train, end to end on a scratch database: board, the carry (the Hecks mint
# step, then the push), the recorded push, then the launcher refresh and the deploy announcement.
# The domain holds the train's own declarations (`PushTrainDepot`) and is split across files; the
# remote is a local bare repository, and the desktop alert and the launcher refresh are stubbed.
# Two worlds: a disposable ledger, whose boot never refuses and whose mint step mints nothing, and
# an ordinary one that mints eras.
RSpec.describe "a push train boarding, from the mint to the announcement", :io do
  END_TO_END_DB = "hecks_push_train_end_to_end_spec".freeze

  scratch_postgres END_TO_END_DB, fenced: true

  # An optional field one side of a move has and the other lacks.
  LANE = "      attribute :lane, Word, optional: true\n".freeze

  # What a mint that refuses reads: an unminted shape no edge covers.
  NO_EDGE = Struct.new(:verdict, :reason).new("needs_edge", "no edge covers the move").freeze

  let(:alert) { instance_double(Hecks::Adapters::DesktopAlert, announce: { report: { value: "Depot is ready" } }) }
  let(:launcher) { instance_double(Hecks::Adapters::GitLauncher, refresh: { report: { value: "launcher moved" } }) }

  def url = FencedOwner.url(END_TO_END_DB)

  def depot = File.join(@scratch, "depot")

  # The mint step the carry runs: the held mint aimed at the depot, reading its facts from `reader`
  # when given and from the depot otherwise.
  def depot_mint(reader)
    held = Hecks::Adapters::JournalStore::HeldMint.new(directory: depot, reader: reader)
    Hecks::Adapters::GitTrain::MintStep.new(mint: held)
  end

  def stub_adapters(reader)
    allow(Hecks::Adapters::GitTrain).to(receive(:new).and_wrap_original do |original, **kw|
      original.call(**kw, mint: depot_mint(reader))
    end)
    allow(Hecks::Adapters::DesktopAlert).to receive(:new).and_return(alert)
    allow(Hecks::Adapters::GitLauncher).to receive(:new).and_return(launcher)
  end

  # Holds era 1 from a copy of the depot shaped by `held`, then writes the depot shaped by `now`.
  # The copy is its own directory, so the depot's files are each loaded from one text.
  def prepare(held: {}, now: {}, disposable: false, reader: nil)
    PushTrainDepot.write!(File.join(@scratch, "held"), url, disposable: disposable, **held)
    PushTrainDepot.hold!(File.join(@scratch, "held"), url)
    PushTrainDepot.write!(depot, url, disposable: disposable, **now)
    stub_adapters(reader)
  end

  def refuse_the_mint = ->(_directory) { { held: 1, status: "unminted", next_era: 2, verdict: NO_EDGE } }

  def runtime
    @work = PushTrainDepot.checkout!(@scratch)
    Hecks.boot(depot, install_driving: false, environment: nil)
  end

  def board(runtime)
    runtime.dispatch_flat("Depot::SendTrain.Board", run: { value: "push-1" }, checkout: { value: @work },
                                                    confirm: { value: true })
  end

  def board!
    runtime = runtime()
    board(runtime)
    runtime.query("Depot::SendTrain.Outcome", run: { value: "push-1" }).first
  end

  def remote_head = PushTrainDepot.git(@work, "ls-remote", "origin", "refs/heads/main").split.first

  def local_head = PushTrainDepot.git(@work, "rev-parse", "main")

  def pushed? = remote_head == local_head

  def era_count
    db = PG.connect(url)
    db.exec("SELECT count(*) AS n FROM hecks_eras WHERE domain = 'Depot'")[0]["n"].to_i
  ensure
    db&.close
  end

  def pushed_commit = hash_including(pushed: { value: local_head })

  around do |example|
    @scratch = Dir.mktmpdir("push-train-e2e")
    example.run
  ensure
    FileUtils.remove_entry(@scratch)
  end

  context "with a disposable ledger and a moved shape" do
    before { prepare(now: { extra: LANE }, disposable: true) }

    it "boards, reports the ledger disposable, and records the push", :aggregate_failures do
      outcome = board!
      expect(outcome[:status]).to eq("pushed")
      expect(outcome[:report][:value])
        .to start_with("pushing 1 commits\nthe Hecks ledger is disposable, so no mint is needed, then")
      expect([pushed?, era_count]).to eq([true, 1])
    end

    it "refreshes the launcher and announces the deploy with the pushed commit", :aggregate_failures do
      board!
      expect(launcher).to have_received(:refresh).with(pushed_commit)
      expect(alert).to have_received(:announce).with(pushed_commit)
    end
  end

  context "with a minting world and a shape that did not move" do
    before { prepare }

    it "passes the mint straight through and records the push", :aggregate_failures do
      outcome = board!
      expect(outcome[:status]).to eq("pushed")
      expect(outcome[:report][:value]).to start_with("pushing 1 commits\nthe Hecks shape").and include("did not move")
      expect(outcome[:report][:value]).to include("boarded #{local_head[0, 9]}", "pushed #{local_head[0, 9]}")
      expect([pushed?, era_count]).to eq([true, 1])
    end

    it "refreshes the launcher and announces the deploy with the pushed commit", :aggregate_failures do
      board!
      expect(launcher).to have_received(:refresh).with(pushed_commit)
      expect(alert).to have_received(:announce).with(pushed_commit)
    end
  end

  context "with a minting world and a refused mint" do
    before { prepare(reader: refuse_the_mint) }

    it "faults the boarding with the mint's reason and pushes nothing", :aggregate_failures do
      outcome = board!
      expect(outcome[:status]).to eq("faulted")
      expect(outcome[:refusal][:value]).to include("the Hecks mint refused this boarding, so nothing was pushed")
        .and include("no edge covers the move")
      expect([pushed?, era_count]).to eq([false, 1])
    end

    it "neither refreshes the launcher nor announces a deploy", :aggregate_failures do
      board!
      expect(launcher).not_to have_received(:refresh)
      expect(alert).not_to have_received(:announce)
    end
  end

  # The known limit: a minting world's boot refuses every write but a mint command's own record, and
  # `SendTrain.Board` is not a mint command. A shape no held era holds is therefore refused at the
  # boarding itself, before the carry can run its mint, whether the mint would cover it or not. The
  # train must run on a disposable ledger, or the shape be minted before it boards.
  context "with a minting world and a shape no held era holds" do
    def refused_boarding = -> { board(runtime) }

    def refusal = raise_error(Hecks::Runtime::WiringError, /the shape is not minted yet; run the mint entry point/)

    it "refuses the boarding's own record when the move is an addition the mint would cover", :aggregate_failures do
      prepare(now: { extra: LANE })
      expect(&refused_boarding).to refusal
      expect([pushed?, era_count]).to eq([false, 1])
    end

    # A boot over a breaking move no edge covers refuses before any record is written (ADR 0168).
    it "refuses the boot itself when the move is one no edge covers", :aggregate_failures do
      prepare(held: { extra: LANE })
      expect(&refused_boarding).to raise_error(Hecks::Runtime::WiringError, /no translation edge covers it/)
      expect([pushed?, era_count]).to eq([false, 1])
    end
  end
end
