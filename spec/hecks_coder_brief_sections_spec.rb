require "spec_helper"

# The standing rules a session was pasted by hand each time, and the sections only a caller knows.
RSpec.describe "the Coder brief's standing sections" do
  let(:coder_root) { File.join(InMemoryDomain::ROOT, "lib/hecks/coder") }

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      Kernel.load(File.join(coder_root, "coder.bluebook"))
      Kernel.load(File.join(coder_root, "coder.hecksagon"))
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def compose(**extra)
    runtime
    Coder::Brief.compose!(work: { value: "work/x" }, outcome: { value: "Retire the old route" }, **extra)
  end

  def section(name) = compose[name][:value]

  it "tells the session how to set up and clean up its worktree" do
    expect(section(:workflow)).to include("LinkedTree.add! branch.value={work}", "Pull main first, always",
                                          "merge-base --is-ancestor origin/main HEAD",
                                          "no Claude attribution trailer", "ignored files")
  end

  it "tells the session how to land" do
    expect(section(:landing)).to include("regenerate_corpus!", "check_shape_ledger!", "--confirm --additive",
                                         "landing.finish!", "rebases onto local main", "in flight", "it queues")
  end

  it "says a claim is verified by a reviewer run, never by the orchestrator" do
    expect(section(:report)).to include("verified by a reviewer run, never by the orchestrator")
  end

  it "forbids the push, the mint and live databases" do
    expect(section(:restraints)).to include("Do not push", "Do not mint", "live database", "client data")
  end

  it "asks the architect by event before any edit, and hands the row back on rethink" do
    expect(section(:review)).to include("Before you edit anything", "PlanReview.request!", "PlanReview.reviews",
                                        "changes: revise the plan", "Work.yield! to={work}", "Quote the verdict")
  end

  it "ends its turn on a [review] question to be resumed, and never polls for the verdict", :aggregate_failures do
    review = section(:review)
    expect(review).to include("end your turn by asking one question that begins [review]", "resumes this same session")
    expect(review).not_to include("Operation.follow", "wait=150", "at most four times")
  end

  it "runs every review command through the main checkout's launcher", :aggregate_failures do
    review = section(:review)
    expect(review).to include("{main}/exe/hecks agents PlanReview.request!", "{main}/exe/hecks agents PlanReview.reviews")
    expect(review.gsub("{main}/exe/hecks", "")).not_to include("exe/hecks agents PlanReview")
  end

  it "listens for the red flag through the main checkout too" do
    expect(section(:restraints)).to include("{main}/exe/hecks Operation.follow domain.value={main}/lib/hecks/hecks")
  end

  it "names the spec path, stash and the comment check" do
    expect(section(:verification)).to include("run_spec_example!", "Never use git stash", "check_comments!",
                                              "600000 ms", "poll loop")
  end

  it "batches the touched spec files into one shared-process call" do
    expect(section(:verification)).to include("ONE call", "run_spec_files!", "isolation.value=shared",
                                              "isolation.value=process")
  end

  it "fixes the report format" do
    expect(section(:report)).to include("file:line", "spec counts", "shape-ledger", "sha")
  end

  it "holds the coordination instruction in the bluebook" do
    expect(section(:coordination)).to include("Do not edit them")
  end

  it "holds the freeze instruction in the bluebook" do
    expect(section(:freeze)).to include("commit and hold", "held for the freeze")
  end
end
