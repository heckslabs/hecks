require "spec_helper"
require "tmpdir"
require "fileutils"

# The ShardPlan aggregate of the CiSpeed bluebook, booted with its real adapters over a scratch
# checkout: a plan is asked for, the previous run's timings are looked for, and the files are
# split from those timings or, when none can be read, by size. The events and the policy that
# produced the last one are the story the CI plan job publishes.
RSpec.describe "CiSpeed::ShardPlan" do
  let(:root) { Dir.mktmpdir("shard-plan-") }
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/ci_speed"), install_driving: false) }

  after { FileUtils.rm_rf(root) }

  def spec_file(name, bytes) = File.write(File.join(root, name), "#" * bytes)

  def lay_out_checkout
    FileUtils.mkdir_p(File.join(root, "spec"))
    { "spec/a_spec.rb" => 10, "spec/b_spec.rb" => 20, "spec/c_spec.rb" => 30, "spec/d_spec.rb" => 400 }
      .each { |name, bytes| spec_file(name, bytes) }
  end

  def write_timings(lines)
    FileUtils.mkdir_p(File.join(root, "timings"))
    File.write(File.join(root, "timings", "log.txt"), lines.join("\n"))
  end

  def request(shards: 2)
    Dir.chdir(root) do
      hecks.dispatch_flat(
        "CiSpeed::ShardPlan.Request",
        name: { value: "rspec" }, shards: { value: shards }, items_from: { value: "glob:spec/*_spec.rb" },
        timings_from: { value: "timings" }, out_dir: { value: "plan" }
      )
    end
  end

  def events = hecks.registry.event_log.map(&:name)

  def planned = hecks.registry.event_log.find { |event| event.name == "ShardPlanned" }

  # One field of the ShardPlanned event, as plain data.
  def shown(field) = Hecks::Runtime::Value.materialize(planned.payload).dig(field, :value)

  def reacted = hecks.registry.reaction_log.map { |row| row[:policy] }

  def group(number) = File.readlines(File.join(root, "plan", "group-#{number}.txt"), chomp: true)

  before { lay_out_checkout }

  context "when the previous run's timings can be read" do
    before do
      write_timings(["spec/a_spec.rb:9.0", "spec/b_spec.rb:1.0", "spec/c_spec.rb:1.0", "spec/d_spec.rb:1.0",
                     "Run options: exclude {:io=>true}"])
      request
    end

    it "emits the request, the fetched timings and the plan, in that order" do
      expect(events).to eq(%w[ShardPlanRequested TimingsFetched ShardPlanned])
    end

    it "plans from the timings, for every shard", :aggregate_failures do
      expect(shown(:source)).to eq("timings")
      expect(shown(:shards)).to eq(2)
    end

    it "balances by seconds, not size: the slowest file stands alone" do
      expect([group(1), group(2)]).to include(["spec/a_spec.rb"])
    end

    it "reacts through the plan policy, not the fallback" do
      expect(reacted).to contain_exactly("FetchTimingsWhenPlanRequested", "PlanFromFetchedTimings")
    end
  end

  context "when no timings can be read" do
    before { request }

    it "emits the request, the unavailable timings and the plan, in that order" do
      expect(events).to eq(%w[ShardPlanRequested TimingsUnavailable ShardPlanned])
    end

    it "plans by size, and the fallback policy is what produced the plan", :aggregate_failures do
      expect(shown(:source)).to eq("size")
      expect(reacted).to contain_exactly("FetchTimingsWhenPlanRequested", "PlanBySizeWhenTimingsUnavailable")
    end

    it "puts the largest file alone" do
      expect([group(1), group(2)]).to include(["spec/d_spec.rb"])
    end
  end

  context "when the timings are malformed" do
    before do
      write_timings(["garbage", "spec/a_spec.rb:oops", ""])
      request
    end

    it "does not fail the run: it falls back to size", :aggregate_failures do
      expect(events).to eq(%w[ShardPlanRequested TimingsUnavailable ShardPlanned])
      expect(shown(:source)).to eq("size")
    end
  end

  context "when a file has no timing" do
    before do
      write_timings(["spec/a_spec.rb:5.0", "spec/b_spec.rb:5.0"])
      request(shards: 4)
    end

    it "prices it at the table's median, so every file is in exactly one group" do
      files = (1..4).flat_map { |number| group(number) }

      expect(files).to match_array(%w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb spec/d_spec.rb])
    end
  end

  describe "RecordTimings" do
    it "says which log a leg timed its files into" do
      hecks.dispatch_flat("CiSpeed::ShardPlan.RecordTimings", name: { value: "rspec" }, recorded_log: { value: "tmp/x.log" })

      expect(events).to eq(%w[TimingsRecorded])
    end
  end
end
