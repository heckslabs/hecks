require "spec_helper"
require "open3"
require "rbconfig"
require "json"

# An interview at a terminal (ADR 0088): hecks asks the agent for a question, records the answer the
# developer types, puts each proposed finding to the developer, and writes a domain only when the
# interview concludes. Each scenario runs in a child process with a fake agent and scripted
# keystrokes, so no model is called and the aggregate constants a boot installs stay out of this one.
RSpec.describe "hecks interview, held at a terminal" do
  INTERVIEW_CHILD = <<~RUBY.freeze
    require "hecks"
    require "json"
    require "stringio"
    require "tmpdir"
    require "fileutils"
    require "hecks/cli/interview_run"

    # Answers from a script; a row of "FAIL" is an agent that cannot answer that turn.
    class FakeAgent
      attr_reader :states
      def initialize(script) = (@script = script; @asked = 0; @read = 0; @states = [])
      def question(state:, asked:)
        @states << state
        row = @script[:questions][(@asked += 1) - 1]
        raise Hecks::Ports::Agent::Unavailable, "claude is not on PATH" if row == "FAIL"
        row && Hecks::Ports::Agent::Question.new(text: row, because: "to learn")
      end
      def proposals(prose:, state:)
        row = @script[:proposals][(@read += 1) - 1]
        raise Hecks::Ports::Agent::Unavailable, "claude did not answer" if row == "FAIL"
        (row || []).map do |p|
          args = p[:args].map { |k, v| { name: k.to_s, field: "value", value: v } }
          Hecks::Ports::Agent::Proposal.new(verb: p[:verb], rationale: p[:why], arguments: args)
        end
      end
    end

    scenario = JSON.parse(ARGV.first, symbolize_names: true)
    dir = File.join(Dir.mktmpdir, "lending")
    (scenario[:seed] || {}).each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path.to_s)))
      File.write(File.join(dir, path.to_s), text)
    end
    ai = scenario[:ai] != false
    agent = ai ? FakeAgent.new(scenario[:agent] || {}) : nil
    output = StringIO.new
    error = nil
    begin
      Hecks::CLI::InterviewRun.call(name: "Lending", adapter: "Memory", dir: dir, expert: "Maria", use_ai: ai, agent: agent,
                                    input: StringIO.new(scenario[:keys].join("\\n") + "\\n"), output: output)
    rescue ArgumentError => e
      error = e.message
    end
    files = Dir.glob("**/*", base: dir).select { |f| File.file?(File.join(dir, f)) }.sort.to_h { |f| [f, File.read(File.join(dir, f))] }
    puts JSON.generate(transcript: output.string, files: files, error: error, state: agent&.states&.last, dir: dir)
  RUBY

  THING = { verb: "SME::Interview.ProposeThing", why: "a book has an ISBN", args: { name: "Book", identifier: "isbn" } }.freeze
  ACTION = { verb: "SME::Interview.ProposeAction", why: "arrival creates a book",
             args: { name: "Shelve", thing: "Book", event: "BookShelved", creates: "true" } }.freeze
  RULE = { verb: "SME::Interview.ProposeRule", why: "a rule", args: { statement: "A book cannot be lent twice" } }.freeze
  FIELD = { verb: "SME::Interview.ProposeField", why: "a book has a condition",
            args: { thing: "Book", name: "condition", values: "good, worn" } }.freeze
  TRANSITION = { verb: "SME::Interview.ProposeTransition", why: "shelving leaves a book shelved",
                 args: { thing: "Book", action: "Shelve", to: "shelved" } }.freeze

  def run_interview(scenario)
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", INTERVIEW_CHILD, JSON.generate(scenario),
                                      chdir: InMemoryDomain::ROOT)
    raise "interview child failed:\n#{err}" unless status.success?

    JSON.parse(out.lines.last, symbolize_names: true).tap { |r| r[:files] = r[:files].transform_keys(&:to_s) }
  end

  let(:ai_script) do
    { questions: ["What do you keep track of?", "What happens when a book arrives?", "Any rules?"],
      proposals: [[THING], [ACTION], [RULE]] }
  end

  ENOUGH_KEYS = ["Books.", "y", "On the shelf.", "y", "done"].freeze
  MIXED_KEYS = ["Books, each with an ISBN.", "y", "We put it on the shelf.", "",
                "A book cannot be lent twice at once.", "n", "done"].freeze
  FIELD_SCRIPT = { questions: ["What do you keep track of?", "What happens, and what does a book have?"],
                   proposals: [[THING], [ACTION, FIELD, TRANSITION]] }.freeze
  FIELD_KEYS = ["Books.", "y", "On the shelf, and each is good or worn.", "y", "y", "n", "done"].freeze
  NOTHING_ACCEPTED_SCRIPT = { questions: ["What do you keep?", "Say more.", "And then?"],
                              proposals: [[THING], [THING], [ACTION]] }.freeze
  NOTHING_ACCEPTED_KEYS = ["Books.", "n", "done", "Books, each with an ISBN.", "y", "On the shelf.", "y", "done"].freeze
  UNAVAILABLE_SCRIPT = { questions: ["FAIL"], proposals: ["FAIL", "FAIL"] }.freeze
  UNAVAILABLE_KEYS = ["Books, each with an ISBN.", "thing", "Book", "isbn", "", "On the shelf.", "action", "Shelve",
                      "Book", "BookShelved", "y", "", "done"].freeze
  NO_AI_KEYS = ["Books.", "thing", "Book", "isbn", "", "On the shelf.", "action", "Shelve", "Book", "BookShelved", "y", "",
                "done"].freeze
  TYPED_FIELD_KEYS = ["Books.", "thing", "Book", "isbn", "field", "Book", "condition", "good, worn", "transition",
                      "Book", "Shelve", "shelved", "", "", "On the shelf.", "action", "Shelve", "Book",
                      "BookShelved", "y", "", "done"].freeze
  EXISTING_BLUEBOOK = "Hecks.bluebook \"Lending\" do\n  # mine\nend\n".freeze
  EXISTING_FILES = { "bluebook/lending.bluebook": EXISTING_BLUEBOOK, "interviews/INT-1.md": "# first\n" }.freeze

  def lending_bluebook(result) = result[:files]["bluebook/lending.bluebook"]

  context "when the developer accepts a thing and an action and rejects a rule" do
    let(:result) { run_interview(agent: ai_script, keys: MIXED_KEYS) }

    it "records what the developer types and puts each finding to them", :aggregate_failures do
      expect(result[:transcript]).to include("Proposed thing: Book, identified by isbn", "Accepted.", "Rejected.")
      expect(result[:files].keys).to eq(%w[bluebook/lending.bluebook bluebook/lending.world interviews/INT-1.md])
    end

    it "writes the domain they accepted", :aggregate_failures do
      expect(lending_bluebook(result)).to include('aggregate "Book" do', 'command "Shelve" do')
      expect(lending_bluebook(result)).not_to include("cannot be lent twice")
      expect(result[:files]["interviews/INT-1.md"]).to include("Rule 3, rejected: A book cannot be lent twice")
    end
  end

  context "when the developer accepts two findings and then ends" do
    let(:result) { run_interview(agent: ai_script, keys: ENOUGH_KEYS) }
    let(:state) { result[:state] }

    it "tells the developer where the answers go before the first question, and suggests ending once there is enough",
       :aggregate_failures do
      expect(result[:transcript]).to include("sent to a model through your own `claude` login")
      expect(result[:transcript]).to include("I think we have enough to start")
    end

    it "sends the agent the subject, the exchanges, what was accepted and the gaps, and no files", :aggregate_failures do
      expect(state.keys.map(&:to_s)).to contain_exactly("task", "subject", "expert", "verbs", "exchanges", "accepted", "gaps")
      expect(state[:subject]).to eq("Lending")
      expect(state[:task]).to include("Do not assume what kind of business it is")
      expect(state[:exchanges].length).to eq(2)
      expect(state[:accepted][:things].first).to eq(name: "Book", identifier: "isbn")
    end

    it "tells the interviewer what a thing is not yet said to have, so it asks next", :aggregate_failures do
      expect(state[:gaps]).to include("nothing is yet said Book has, beyond its identifier")
      expect(state[:accepted].keys.map(&:to_s)).to include("fields", "transitions")
    end
  end

  context "when the agent proposes a field and a transition" do
    let(:result) { run_interview(agent: FIELD_SCRIPT, keys: FIELD_KEYS) }

    it "puts a proposed field and transition to the developer", :aggregate_failures do
      expect(result[:transcript]).to include("Proposed field: condition of Book, one of good, worn",
                                             "Proposed transition: Shelve leaves Book shelved")
    end

    it "writes the field they accepted, and records the transition they rejected", :aggregate_failures do
      expect(lending_bluebook(result)).to include("attribute :condition, Condition, optional: true",
                                                  'one_of: ["good", "worn"]')
      expect(result[:files]["interviews/INT-1.md"]).to include("- Transition 4, rejected: **Shelve** on Book to shelved")
    end
  end

  it "ignores a field proposal with no name, and says so" do
    nameless = FIELD.merge(args: { thing: "Book", values: "good, worn" })
    script = { questions: ["What do you keep track of?", "What happens?"], proposals: [[THING], [ACTION, nameless]] }
    result = run_interview(agent: script, keys: ["Books.", "y", "On the shelf.", "y", "done"])

    expect(result[:transcript]).to include("Ignored a field proposal with no name.")
  end

  it "refuses to finish with nothing accepted, says why, and carries on", :aggregate_failures do
    result = run_interview(agent: NOTHING_ACCEPTED_SCRIPT, keys: NOTHING_ACCEPTED_KEYS)

    expect(result[:transcript]).to include("Not finished yet: a thing must be accepted before the interview ends")
    expect(result[:files].keys).to include("bluebook/lending.bluebook")
  end

  it "stops and writes nothing when the developer quits", :aggregate_failures do
    result = run_interview(agent: ai_script, keys: ["Books.", "y", "quit"])

    expect(result[:transcript]).to include("Stopped. Nothing was written.")
    expect(result[:files]).to be_empty
  end

  it "says what failed when the agent cannot answer, and uses a plain prompt for that turn", :aggregate_failures do
    result = run_interview(agent: UNAVAILABLE_SCRIPT, keys: UNAVAILABLE_KEYS)

    expect(result[:transcript]).to include("The AI could not answer (claude is not on PATH)", "What is the main thing")
    expect(result[:transcript]).to include("The AI could not answer (claude did not answer)")
    expect(result[:files].keys).to include("bluebook/lending.bluebook")
    expect(lending_bluebook(result)).to include('aggregate "Book" do', 'command "Shelve" do')
  end

  it "runs with fixed questions and typed findings under --no-ai, and says nothing about a model", :aggregate_failures do
    result = run_interview(ai: false, keys: NO_AI_KEYS)

    expect(result[:transcript]).not_to include("sent to a model")
    expect(result[:transcript]).to include("What is the main thing this business keeps track of?")
    expect(lending_bluebook(result)).to include('aggregate "Book" do', 'command "Shelve" do')
  end

  it "takes a typed field and a typed transition under --no-ai, leaving the optional parts blank", :aggregate_failures do
    result = run_interview(ai: false, keys: TYPED_FIELD_KEYS)

    expect(lending_bluebook(result)).to include("attribute :condition, Condition, optional: true", 'one_of: ["good", "worn"]')
    expect(result[:files]["interviews/INT-1.md"]).to include("**Shelve** on Book to shelved (exchange 1)")
  end

  it "offers a later interview's findings as additions, and leaves the existing bluebook alone", :aggregate_failures do
    result = run_interview(agent: ai_script, seed: EXISTING_FILES, keys: ENOUGH_KEYS)

    expect(lending_bluebook(result)).to eq(EXISTING_BLUEBOOK)
    expect(result[:files]["interviews/INT-2.md"]).to include("## Proposed additions", 'aggregate "Book" do')
    expect(result[:files]["interviews/INT-1.md"]).to eq("# first\n")
  end
end
