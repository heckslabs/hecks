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

  it "records what the developer types, puts each finding to them, and writes the domain they accepted" do
    result = run_interview(agent: ai_script, keys: ["Books, each with an ISBN.", "y", "We put it on the shelf.", "",
                                                    "A book cannot be lent twice at once.", "n", "done"])

    expect(result[:transcript]).to include("Proposed thing: Book, identified by isbn", "Accepted.", "Rejected.")
    expect(result[:files].keys).to eq(%w[bluebook/lending.bluebook bluebook/lending.world interviews/INT-1.md])
    expect(result[:files]["bluebook/lending.bluebook"]).to include('aggregate "Book" do', 'command "Shelve" do')
    expect(result[:files]["bluebook/lending.bluebook"]).not_to include("cannot be lent twice")
    expect(result[:files]["interviews/INT-1.md"]).to include("Rule 3, rejected: A book cannot be lent twice")
  end

  it "tells the developer where the answers go before the first question, and suggests ending once there is enough" do
    result = run_interview(agent: ai_script, keys: ["Books.", "y", "On the shelf.", "y", "done"])

    expect(result[:transcript]).to include("sent to a model through your own `claude` login")
    expect(result[:transcript]).to include("I think we have enough to start")
  end

  it "sends the agent the subject, the exchanges, what was accepted and the gaps, and no files" do
    result = run_interview(agent: ai_script, keys: ["Books.", "y", "On the shelf.", "y", "done"])

    expect(result[:state].keys.map(&:to_s)).to contain_exactly("task", "subject", "expert", "verbs", "exchanges", "accepted",
                                                               "gaps")
    expect(result[:state][:subject]).to eq("Lending")
    expect(result[:state][:task]).to include("Do not assume what kind of business it is")
    expect(result[:state][:exchanges].length).to eq(2)
    expect(result[:state][:accepted][:things].first).to eq(name: "Book", identifier: "isbn")
  end

  it "refuses to finish with nothing accepted, says why, and carries on" do
    script = { questions: ["What do you keep?", "Say more.", "And then?"], proposals: [[THING], [THING], [ACTION]] }
    result = run_interview(agent: script,
                           keys:  ["Books.", "n", "done", "Books, each with an ISBN.", "y",
                                   "On the shelf.", "y", "done"])

    expect(result[:transcript]).to include("Not finished yet: a thing must be accepted before the interview ends")
    expect(result[:files].keys).to include("bluebook/lending.bluebook")
  end

  it "stops and writes nothing when the developer quits" do
    result = run_interview(agent: ai_script, keys: ["Books.", "y", "quit"])

    expect(result[:transcript]).to include("Stopped. Nothing was written.")
    expect(result[:files]).to be_empty
  end

  it "says what failed when the agent cannot answer, and uses a plain prompt for that turn" do
    script = { questions: ["FAIL"], proposals: %w[FAIL FAIL] }
    result = run_interview(agent: script, keys: ["Books, each with an ISBN.", "thing", "Book", "isbn", "",
                                                 "On the shelf.", "action", "Shelve", "Book", "BookShelved", "y", "", "done"])

    expect(result[:transcript]).to include("The AI could not answer (claude is not on PATH)", "What is the main thing")
    expect(result[:transcript]).to include("The AI could not answer (claude did not answer)")
    expect(result[:files].keys).to include("bluebook/lending.bluebook")
    expect(result[:files]["bluebook/lending.bluebook"]).to include('aggregate "Book" do', 'command "Shelve" do')
  end

  it "runs with fixed questions and typed findings under --no-ai, and says nothing about a model" do
    result = run_interview(ai: false, keys: ["Books.", "thing", "Book", "isbn", "", "On the shelf.", "action", "Shelve", "Book",
                                             "BookShelved", "y", "", "done"])

    expect(result[:transcript]).not_to include("sent to a model")
    expect(result[:transcript]).to include("What is the main thing this business keeps track of?")
    expect(result[:files]["bluebook/lending.bluebook"]).to include('aggregate "Book" do', 'command "Shelve" do')
  end

  it "offers a later interview's findings as additions, and leaves the existing bluebook alone" do
    bluebook = "Hecks.bluebook \"Lending\" do\n  # mine\nend\n"
    result = run_interview(agent: ai_script, seed: { "bluebook/lending.bluebook": bluebook, "interviews/INT-1.md": "# first\n" },
                           keys: ["Books.", "y", "On the shelf.", "y", "done"])

    expect(result[:files]["bluebook/lending.bluebook"]).to eq(bluebook)
    expect(result[:files]["interviews/INT-2.md"]).to include("## Proposed additions", 'aggregate "Book" do')
    expect(result[:files]["interviews/INT-1.md"]).to eq("# first\n")
  end
end
