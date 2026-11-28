require "spec_helper"
require "hecks"
require "hecks/tools/model_check"
require "tmpdir"

# `hecks model_check` refuses two contexts that depend on each other, read off the wiring of every
# domain it boots, and a context map that accepts the cycle excuses nothing (ADR 0207). Two scratch
# domains each subscribe to the other's event, so each depends on the other.
RSpec.describe "model_check over two contexts that depend on each other" do
  # The way out the refusal names, after the contexts it lists.
  WAYS_OUT = "a context is upstream of another or downstream of it, never both; move the reactions " \
             "to one side's hecksagon, or make them one context".freeze

  # @return [String] a bluebook whose one command emits `event`
  def bluebook(name, event)
    <<~RUBY
      Hecks.bluebook "#{name}" do
        vision "A context that answers the other one."
        aggregate "Signal" do
          identified_by :ref
          attribute :ref, Ref
          value_object("Ref") { attribute :value, String }
          command("Send") { role "Tester"; goal "Send a signal"; attribute :ref, Ref; emits "#{event}" }
        end
      end
    RUBY
  end

  # Writes the domain `name` under `root`, with a hecksagon listening for `heard` when given (a
  # domain that hears nothing has none), and returns its directory.
  def domain(root, name, emits:, heard:, map: nil)
    dir = File.join(root, name.downcase).tap { |path| Dir.mkdir(path) }
    File.write(File.join(dir, "#{name.downcase}.bluebook"), bluebook(name, emits))
    File.write(File.join(dir, "#{name.downcase}.hecksagon"), wiring(name, heard)) if heard
    File.write(File.join(dir, "pair.contextmap"), map) if map
    dir
  end

  # @return [String] a hecksagon for `name` that subscribes to `heard`
  def wiring(name, heard)
    %(Hecks.hecksagon "#{name}" do\n  subscribe "#{heard}"\nend\n)
  end

  # @return [Array(Integer, String)] the status the check exits with, and what it printed
  def checked(map: nil, back: "Right.Ponged")
    Dir.mktmpdir do |root|
      dirs = [domain(root, "Left", emits: "Pinged", heard: back, map: map),
              domain(root, "Right", emits: "Ponged", heard: "Left.Pinged")]
      printed(dirs)
    end
  end

  # Runs the check over `dirs` with its output captured.
  def printed(dirs)
    held = $stdout
    $stdout = StringIO.new
    [exit_status { Hecks::Tools::ModelCheck.call(dirs, program: "hecks model_check") }, $stdout.string]
  ensure
    $stdout = held
  end

  def exit_status
    yield
    :returned
  rescue SystemExit => e
    e.status
  end

  # A map that accepts the pair's cycle on the relationship it declares.
  let(:accepting_map) do
    <<~RUBY
      Hecks.context_map "Pair" do
        context "Left"
        context "Right"
        relate "Right" => "Left", as: :customer_supplier, accepted_findings: { context_cycle: "stood before" }
      end
    RUBY
  end

  it "passes when only one context listens to the other" do
    expect(checked(back: nil).first).to eq(0)
  end

  it "exits 1, naming the two contexts and the ways out", :aggregate_failures do
    status, out = checked
    expect(status).to eq(1)
    expect(out).to include("Left <-> Right  —  these contexts depend on each other: Left, Right — #{WAYS_OUT}\n")
  end

  it "exits 1 when the context map accepts the cycle, saying the acceptance excuses nothing", :aggregate_failures do
    status, out = checked(map: accepting_map)
    expect(status).to eq(1)
    expect(out).to include("the context map accepts the cycle between Left and Right (accepted_findings: " \
                           "{ context_cycle: ... }), which excuses no cycle from 8.0.0")
  end
end
