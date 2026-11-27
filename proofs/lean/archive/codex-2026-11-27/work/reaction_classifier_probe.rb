require "json"
require "hecks"
require "hecks/runtime/reaction_outcome"

classifier = Hecks::Runtime::ReactionOutcome
event_of = ->(row) { row[:event_id] }
base = { policy: "RefuseLedger", trigger: "Shop::Ledger.Record",
         on: "OrderPlaced", delivered: false, reason: "deliberate refusal", event_id: "e1" }
same = { policy: "AcceptLedger", trigger: "Shop::Ledger.Accept",
         on: "OrderPlaced", delivered: true, event_id: "e1" }
other_event = same.merge(event_id: "e2")
other_aggregate = same.merge(trigger: "Shop::Audit.Accept")
already = { policy: "CreatePizza", trigger: "Pizzas::Order.CreatePizza",
            on: "PizzaRequested", delivered: false,
            reason: 'CreatePizza creates a Order that already exists — name.value "First"', event_id: "e3" }
wrong_creator = already.merge(trigger: "Pizzas::Order.MakePizza")
ask_refusal = base.merge(policy: "AskOutside", refuses: "OutsideRefused")
ask_answer = { policy: "HandleOutsideRefusal", trigger: "Shop::Ledger.Accept",
               on: "OutsideRefused", delivered: true, event_id: "e4" }

cases = {
  lone_refusal: [base],
  same_event_alternative: [base, same],
  different_event: [base, other_event],
  missing_event_identity: [base, same.merge(event_id: nil)],
  different_aggregate: [base, other_aggregate],
  idempotent_duplicate: [already],
  wrong_creator: [wrong_creator],
  answered_ask: [ask_refusal, ask_answer],
  held_store: [base.merge(held: true)],
  defect: [base.merge(defect: true, error_class: "RuntimeError")]
}
results = cases.to_h do |name, rows|
  [name, { blocking: classifier.blocking(rows, event_of: event_of).map { |row| row[:policy] },
           defects: classifier.defects(rows).map { |row| row[:policy] } }]
end
expected = {
  lone_refusal: ["RefuseLedger"], same_event_alternative: [],
  different_event: ["RefuseLedger"], missing_event_identity: [],
  different_aggregate: ["RefuseLedger"],
  idempotent_duplicate: [], wrong_creator: ["CreatePizza"],
  answered_ask: [], held_store: [], defect: []
}
expected.each { |name, blockers| raise "#{name} mismatch" unless results.fetch(name)[:blocking] == blockers }
raise "defect disappeared" unless results[:defect][:defects] == ["RefuseLedger"]
puts JSON.pretty_generate(results)
