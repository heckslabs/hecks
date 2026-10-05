require "spec_helper"
require "open3"
require "rbconfig"
require "json"

# The SME chapter (ADR 0088): an interview is one sitting, answers are recorded only while it is
# underway, findings cite an exchange and are accepted or rejected by name, and an interview ends
# only with a thing and an action accepted. The chapter ships in the gem and is not attached to the
# Hecks domain, so no `hecks` command boots it.
RSpec.describe "the SME chapter" do
  # Runs in a child process: the aggregate constants a boot installs would otherwise join this
  # process's namespace. Each step prints `label=outcome`, where a refusal reads `REFUSED:<class>`.
  INTERVIEW_SCRIPT = <<~RUBY.freeze
    require "hecks"
    rt = Hecks.boot("lib/hecks/sme")
    def step(label)
      value = yield
      puts "\#{label}=\#{value.nil? ? 'ok' : value}"
    rescue StandardError => e
      puts "\#{label}=REFUSED:\#{e.class.name.split('::').last}:\#{e.message}"
    end
    def decide(rt, entity, verb, number)
      rt.dispatch_flat("SME::Interview.\#{entity}.\#{verb}", reference: { value: "INT-1" }, number: { value: number })
      nil
    end

    i = Interview.plan!(reference: "INT-1", subject: "Lending", expert: "Maria")
    step("planned") { i.status }
    step("record_before_begin") { i.record!(question: "q", answer: "a"); nil }
    i.begin!
    step("conclude_empty") { i.conclude!; nil }
    i.record!(question: "What do you keep track of?", answer: "Books, each with an ISBN.", topic: "catalogue")
    i.record!(question: "What happens to a book?", answer: "It is lent to one person.")
    step("exchanges") { i.exchanges.size }
    step("first_topic") { i.exchanges.first[:topic] || i.exchanges.first.to_h[:topic] }
    step("cite_unrecorded_exchange") { i.propose_thing!(number: 1, name: "Book", identifier: "isbn", source: 9); nil }
    i.propose_thing!(number: 1, name: "Book", identifier: "isbn", source: 1)
    i.propose_action!(number: 2, name: "Lend", thing: "Book", event: "BookLent", takes: "borrower", by: "a librarian", source: 2)
    i.propose_rule!(number: 3, statement: "A book cannot be lent twice at once", source: 2)
    i.propose_field!(number: 4, thing: "Book", name: "condition", values: "good, worn", source: 1)
    i.propose_transition!(number: 5, thing: "Book", action: "Lend", to: "lent", from: "shelved", source: 2)
    step("conclude_nothing_accepted") { i.conclude!; nil }
    step("accept_thing") { decide(rt, "ThingFinding", "AcceptThing", 1) }
    step("conclude_without_action") { Interview.find("INT-1").conclude!; nil }
    step("accept_action") { decide(rt, "ActionFinding", "AcceptAction", 2) }
    step("accept_action_twice") { decide(rt, "ActionFinding", "AcceptAction", 2) }
    step("reject_rule") { decide(rt, "RuleFinding", "RejectRule", 3) }
    step("accept_field") { decide(rt, "FieldFinding", "AcceptField", 4) }
    step("accept_field_twice") { decide(rt, "FieldFinding", "AcceptField", 4) }
    step("reject_transition") { decide(rt, "TransitionFinding", "RejectTransition", 5) }
    step("field_without_values") { Interview.find("INT-1").propose_field!(number: 6, thing: "Book", name: "title", source: 1); nil }
    step("transition_without_from") { Interview.find("INT-1").propose_transition!(number: 7, thing: "Book", action: "Shelve", to: "shelved", source: 1); nil }
    step("conclude") { Interview.find("INT-1").conclude!; nil }
    final = Interview.find("INT-1")
    step("status") { final.status }
    step("record_after_conclude") { final.record!(question: "q", answer: "a"); nil }
    step("tallies") { "\#{final.accepted_things.value},\#{final.accepted_actions.value}" }
    step("rule_status") { final.rule_findings.first[:status] }
    step("field_status") { final.field_findings.first[:status] }
    step("transition_status") { final.transition_findings.first[:status] }
    step("action_takes") { final.action_findings.first[:takes].to_h[:value].to_s }
    step("action_by") { final.action_findings.first[:by].to_h[:value].to_s }
  RUBY

  let(:outcome) do
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", INTERVIEW_SCRIPT, chdir: InMemoryDomain::ROOT)
    raise "interview script failed:\n#{err}" unless status.success?

    out.lines.to_h { |line| line.chomp.split("=", 2) }
  end

  it "keeps an interview to one sitting: planned, then underway, then concluded" do
    expect(outcome.values_at("planned", "status")).to eq(%w[planned concluded])
    expect(outcome["record_before_begin"]).to match(/REFUSED:GivenNotMet:.*only while the interview is underway/)
    expect(outcome["record_after_conclude"]).to match(/REFUSED:GivenNotMet:.*only while the interview is underway/)
  end

  it "keeps each exchange in order, with an optional topic" do
    expect(outcome["exchanges"]).to eq("2")
    expect(outcome["first_topic"]).to eq("catalogue")
  end

  it "refuses a finding that cites an exchange nobody recorded" do
    expect(outcome["cite_unrecorded_exchange"]).to match(/REFUSED:GivenNotMet:.*cites an exchange that was recorded/)
  end

  it "ends only with an exchange recorded and a thing and an action accepted" do
    expect(outcome["conclude_empty"]).to match(/REFUSED:GivenNotMet:.*recorded nothing/)
    expect(outcome["conclude_nothing_accepted"]).to match(/REFUSED:GivenNotMet:.*a thing must be accepted/)
    expect(outcome["conclude_without_action"]).to match(/REFUSED:GivenNotMet:.*an action must be accepted/)
    expect(outcome["tallies"]).to eq("1,1")
  end

  it "decides a finding once: accepting twice is refused, and a rule can be rejected" do
    expect(outcome["accept_thing"]).to eq("ok")
    expect(outcome["accept_action_twice"]).to match(/REFUSED:LifecycleRefused:.*moves it only from "proposed"/)
    expect(outcome["rule_status"]).to eq("rejected")
  end

  it "keeps what a thing has and how it changes state as findings decided the same way" do
    expect(outcome["accept_field"]).to eq("ok")
    expect(outcome["accept_field_twice"]).to match(/REFUSED:LifecycleRefused:.*moves it only from "proposed"/)
    expect(outcome.values_at("field_status", "transition_status")).to eq(%w[accepted rejected])
  end

  it "lets a field leave its values out and a transition leave its from out" do
    expect(outcome.values_at("field_without_values", "transition_without_from")).to eq(%w[ok ok])
  end

  it "keeps what an action takes and who does it" do
    expect(outcome["action_takes"]).to include("borrower")
    expect(outcome["action_by"]).to include("a librarian")
  end

  it "ships in the gem" do
    shipped = Gem::Specification.load(File.join(InMemoryDomain::ROOT, "hecks.gemspec")).files

    expect(shipped).to include("lib/hecks/sme/bluebook/sme.bluebook", "lib/hecks/sme/bluebook/sme.hecksagon")
  end

  it "is not attached to the Hecks domain, so no hecks command boots it" do
    hecksagon = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks/hecks.hecksagon"))

    expect(hecksagon).not_to include("SME")
  end
end
