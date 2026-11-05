require "hecks"
require "tmpdir"
require "fileutils"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"
require_relative "../../../../lib/hecks/hecks/adapters/git_train/mint_step"

# The held mint, and the push train's mint step that asks it, for a world that declares
# `disposable_ledger true`: the boot brings the store to its shape, so the mint passes straight
# through, refusing nothing and minting no era.
RSpec.describe "the held mint of a disposable ledger" do
  def fixture = File.expand_path("../../../fixtures/rehearsal/shop/bluebook", __dir__)

  def minter_calls = @minter_calls ||= []

  def held_mint_class = Hecks::Adapters::JournalStore::HeldMint

  after { FileUtils.remove_entry(@scratch) if @scratch }

  def held_mint(facts)
    held_mint_class.new(directory: "unused", reader: ->(_dir) { facts }, minter: ->(*call) { minter_calls << call })
  end

  # A copy of the shop fixture whose world adds `line` to its Postgres block.
  def shop_declaring(line)
    @scratch = Dir.mktmpdir("held-mint-disposable")
    directory = File.join(@scratch, "bluebook")
    FileUtils.cp_r(fixture, directory)
    world = File.join(directory, "shop.world")
    File.write(world, File.read(world).sub(/(persisted_by\("PostgresEra"\) do\n)/, "\\1    #{line}\n"))
    directory
  end

  it "passes through, minting nothing", :aggregate_failures do
    answer = held_mint({ disposable: true }).answer(run: "push-1", confirm: true)
    expect(answer[:outcome]).to eq({ value: "disposable" })
    expect(minter_calls).to be_empty
  end

  it "lets the mint step report that no mint is needed" do
    step = Hecks::Adapters::GitTrain::MintStep.new(mint: held_mint({ disposable: true }))
    expect(step.run(run: "push-1", confirm: true)).to eq("the Hecks ledger is disposable, so no mint is needed")
  end

  it "reads a world that declares the ledger disposable as disposable, before it reads any era" do
    expect(held_mint_class.read(shop_declaring("disposable_ledger true"))).to eq({ disposable: true })
  end

  it "still refuses an unconfirmed mint of a disposable ledger" do
    expect { held_mint({ disposable: true }).answer(run: "push-1") }
      .to raise_error(Hecks::Runtime::WiringError, /needs --confirm/)
  end
end
