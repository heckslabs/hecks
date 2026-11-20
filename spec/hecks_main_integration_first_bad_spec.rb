require "spec_helper"
require "hecks/hecks/adapters/main_verification"

# A stand-in for a range of landings and the probe of a search over it: each merge is red or
# green, the first parent of a merge is the merge before it, and that of the oldest is the base.
# One commit can be flaky: its first run reads the other way.
class FirstBadHistory
  # @param red [Array<Boolean>] whether the example is red at each merge, oldest first
  # @param base_red [Boolean] whether it is red at the base
  # @param flaky [Integer, nil] the merge whose first run reads the other way, -1 the base
  def initialize(red, base_red: false, flaky: nil)
    @red = red
    @base_red = base_red
    @flaky = flaky
    @seen = Hash.new(0)
  end

  # @return [Array<Hash>] the merges, oldest first
  def merges = Array.new(@red.size) { |index| { sha: "sha#{index}", subject: "merge #{index}", paths: [] } }

  # @return [Array(Boolean, Hash)] the probe's answer at the merge
  def call(merge) = at(merge[:sha].delete_prefix("sha").to_i)

  # @return [Array(Boolean, Hash)] the probe's answer at the merge's first parent
  def before(merge) = at(merge[:sha].delete_prefix("sha").to_i - 1)

  private

  def at(index)
    red = index.negative? ? @base_red : @red[index]
    red = !red if index == @flaky && (@seen[index] += 1) == 1
    [!red, ({ spec: "spec/x_spec.rb" } if red)]
  end
end

# The search for the first bad merge: a walk back from the newest landing that reads facts and
# decides nothing. A merge is named only when the failing example is red at it and green at its
# first parent, each read twice.
RSpec.describe Hecks::Adapters::MainIntegration::FirstBad do
  # A range of `size` merges, red at the `red` indexes.
  def history(size, red, **)
    FirstBadHistory.new(Array.new(size) { |index| red.include?(index) }, **)
  end

  def search_of(history, **) = described_class.new(history.merges, probe: history, **)

  def searched(size, red, **)
    search_of(history(size, red, **)).tap(&:call)
  end

  it "names the merge where the red that stands at the newest merge began", :aggregate_failures do
    found = search_of(history(8, 5..7)).call
    expect(found[:sha]).to eq("sha5")
    expect(found[:finding]).to eq(spec: "spec/x_spec.rb")
  end

  it "walks back from the newest merge, then runs the merge again and its first parent twice" do
    expect(searched(8, 5..7).log)
      .to eq(["sha7 red", "sha6 red", "sha5 red", "sha4 green", "sha5 red", "sha5^ green", "sha5^ green"])
  end

  it "names the oldest merge when every merge is red and the base is green" do
    expect(search_of(history(3, 0..2)).call[:sha]).to eq("sha0")
  end

  it "names nothing when the example is red at the merge's first parent too", :aggregate_failures do
    search = search_of(history(3, 0..2, base_red: true))
    expect(search.call).to be_nil
    expect(search.reason).to eq("sha0 is red and so is its parent")
  end

  it "names the second break, and never visits a break a later merge mended", :aggregate_failures do
    search = search_of(history(8, [1, 2, 6, 7]))
    expect(search.call[:sha]).to eq("sha6")
    expect(search.log.join).not_to include("sha1", "sha2")
  end

  it "names nothing when the example is green at the newest merge", :aggregate_failures do
    search = searched(8, 1..3)
    expect(search.log).to eq(["sha7 green"])
    expect(search.reason).to eq("no merge in the range turns the failing specs red")
  end

  it "names nothing in a range of no merges" do
    expect(search_of(history(0, [])).call).to be_nil
  end

  it "reports a merge whose second run is green as flaky, and names nothing", :aggregate_failures do
    search = search_of(history(8, 6..7, flaky: 5))
    expect(search.call).to be_nil
    expect(search.flaky).to eq(["sha5"])
    expect(search.reason).to eq("flaky: the failing example flips between two runs at sha5")
  end

  it "reports a first parent whose two runs disagree as flaky, and names nothing", :aggregate_failures do
    search = search_of(history(3, 0..2, flaky: -1))
    expect(search.call).to be_nil
    expect(search.flaky).to eq(["sha0^"])
    expect(search.reason).to eq("flaky: the failing example flips between two runs at sha0^")
  end

  it "names nothing, saying the red run is longer than the budget, in a long red range", :aggregate_failures do
    search = searched(40, 0..39)
    expect(search.log.size).to eq(13)
    expect(search.reason).to eq("the red run is longer than the probe budget of 16: red from sha27 to the newest merge")
  end

  it "finds a recent break in a range far longer than the budget" do
    expect(search_of(history(200, 195..199)).call[:sha]).to eq("sha195")
  end

  it "keeps three probes of its budget back for the candidate's repeat run and its first parent's two" do
    expect(search_of(history(8, 6..7), limit: 5).tap(&:call).log).to eq(["sha7 red", "sha6 red"])
  end

  it "answers nil, saying why, when a probe raises", :aggregate_failures do
    search = described_class.new(history(3, []).merges, probe: ->(_) { raise "boom" })
    expect(search.call).to be_nil
    expect(search.reason).to eq("the search stopped: boom")
  end

  # Random ranges with one injected break that stands to the newest merge, sometimes an earlier
  # break a later merge mended, sometimes one flaky commit. The search names the injected merge
  # or nothing, never another: nothing when the red run outlasts the budget or the flaky commit
  # is one the walk reads (the merge's first parent or any merge after it).
  describe "the search names the injected culprit" do
    walked = described_class::LIMIT - described_class::CONFIRMING

    # @return [Hash] `size`, the `culprit` index, the `red` indexes, and `flaky` (nil for none)
    def drawn(random)
      size = random.rand(1..60)
      culprit = random.rand(0...size)
      { size: size, culprit: culprit, red: [*mended(random, culprit), *(culprit...size)], flaky: flake(random, size) }
    end

    # An earlier break, mended at least two merges before the culprit.
    def mended(random, culprit)
      return [] if culprit < 4 || random.rand < 0.5

      from = random.rand(0..(culprit - 3))
      (from..random.rand(from..(culprit - 3))).to_a
    end

    def flake(random, size) = random.rand < 0.4 ? random.rand(-1...size) : nil

    def named(range)
      search_of(history(range[:size], range[:red], flaky: range[:flaky])).call&.fetch(:sha)
    end

    define_method(:expected) do |range|
      probes = range[:size] - range[:culprit] + (range[:culprit].zero? ? 0 : 1)
      read = range[:flaky] && range[:flaky] >= range[:culprit] - 1
      "sha#{range[:culprit]}" unless probes > walked || read
    end

    def wrong(seed)
      range = drawn(Random.new(seed))
      found = named(range)
      "seed #{seed}: named #{found.inspect}, not #{expected(range).inspect}, in #{range}" unless found == expected(range)
    end

    it "over 500 seeded ranges, naming the seed of any range it gets wrong" do
      expect((1..500).filter_map { |seed| wrong(seed) }).to eq([])
    end
  end
end
