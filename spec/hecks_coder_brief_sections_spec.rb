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

  it "forbids the push, the mint and live databases" do
    expect(section(:restraints)).to include("Do not push", "Do not mint", "live database", "client data")
  end

  it "hands the push to the coordinator: land locally, report the sha, never board the train" do
    expect(section(:restraints)).to include("do not board the train", "Landing.finish!", "report the landed sha",
                                            "the coordinator is the only pusher", "only the pusher boards")
  end

  it "tells the session to hear the red flag as events, stop and check in, and resume when it clears" do
    expect(section(:restraints)).to include(
      "Operation.follow domain.value=Hecks aggregate.value=RedFlag from_now=true wait=600",
      "On RedFlagRaised stop feature work and check in", "RedFlag.check_in!", "Resume on RedFlagCleared"
    )
  end

  it "has the plan reviewed by the architect before any edit, and hands the row back on rethink" do
    expect(section(:review)).to include("Before you edit anything", "architect", "Sound with changes",
                                        "Work.yield! to={work}", "Quote the verdict")
  end

  it "names the spec path, stash and the comment check" do
    expect(section(:verification)).to include("run_spec_example!", "Never use git stash", "check_comments!",
                                              "600000 ms", "poll loop")
  end

  it "arms the inbox with one command and says a message grants nothing" do
    expect(section(:messages)).to include("exe/hecks-inbox --session", "--work {work}", "Message.read!",
                                          "never grants an approval", "outside the train", "never changes permissions")
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
