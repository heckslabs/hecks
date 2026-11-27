require "json"
require "tmpdir"
require "hecks"

def run_fanout(policy_names, same_aggregate: false)
  Dir.mktmpdir("crystal-fanout-") do |sandbox|
    policies = policy_names.map do |name|
      target = if name == "RefuseLedger"
        "Ledger::Record"
      elsif same_aggregate
        "Ledger::Accept"
      else
        "Audit::Record"
      end
      <<~POLICY
        policy "#{name}" do
          on "OrderPlaced"
          trigger #{target}, with: { number: :number }
        end
      POLICY
    end.join("\n")
    File.write(File.join(sandbox, "shop.bluebook"), <<~BLUEBOOK)
      Hecks.bluebook "Shop" do
        vision "Observe ordered sibling reactions."
        core
        aggregate "Order" do
          value_object("Number") { attribute :value, String }
          attribute :number, Number
          identified_by :number
          command "Place" do
            attribute :number, Number
            sets :number
            emits "OrderPlaced"
          end
        end
        aggregate "Ledger" do
          value_object("Number") { attribute :value, String }
          attribute :number, Number
          identified_by :number
          command "Record" do
            attribute :number, Number
            given("deliberate refusal") { false }
            sets :number
            emits "LedgerRecorded"
          end
          command "Accept" do
            attribute :number, Number
            sets :number
            emits "LedgerAccepted"
          end
        end
        aggregate "Audit" do
          value_object("Number") { attribute :value, String }
          attribute :number, Number
          identified_by :number
          command "Record" do
            attribute :number, Number
            sets :number
            emits "AuditRecorded"
          end
        end
      #{policies}
      end
    BLUEBOOK
    File.write(File.join(sandbox, "shop.hecksagon"), <<~HECKSAGON)
      Hecks.hecksagon "Shop" do
        persisted_by "Memory"
      end
    HECKSAGON
    runtime = Hecks.boot(sandbox)
    result = runtime.dispatch_flat("Shop::Order.Place", number: { value: "o-1" })
    observed = { declared_policies: policy_names,
      command: "success", result_refusals: result.refused_reactions.map { |r| r[:policy] },
      result_blockers: result.blocking_reactions.map { |r| r[:policy] },
      reactions: runtime.reactions.map { |r| { policy: r[:policy], delivered: r[:delivered] } },
      events: runtime.events.map(&:name),
      outbox: runtime.outbox.rows.map { |r| { consumer: r.consumer, status: r.status } } }
    runner = Hecks::Adapters::Driving::CliRunner
    _, ordinary_status = runner.call(runtime: runtime,
      argv: ["order.place!", "number.value=o-2"], program: "hecks")
    _, waited_status = runner.call(runtime: runtime,
      argv: ["order.place!", "number.value=o-3", "--wait"], program: "hecks")
    observed.merge(cli_status: { ordinary: ordinary_status, waited: waited_status })
  end
end

first = run_fanout(["RefuseLedger", "RecordAudit"])
second = run_fanout(["RecordAudit", "RefuseLedger"])
alternative = run_fanout(["RefuseLedger", "RecordAudit"], same_aggregate: true)
raise "first ordering mismatch" unless first[:reactions] ==
  [{ policy: "RefuseLedger", delivered: false }, { policy: "RecordAudit", delivered: true }]
raise "second ordering mismatch" unless second[:reactions] ==
  [{ policy: "RecordAudit", delivered: true }, { policy: "RefuseLedger", delivered: false }]
raise "primary command changed" unless [first, second].all? { |r| r[:command] == "success" && r[:events] == %w[OrderPlaced AuditRecorded] }
raise "different aggregate refusal should block" unless first[:result_blockers] == ["RefuseLedger"]
raise "same aggregate alternative should excuse refusal" unless alternative[:result_refusals] == ["RefuseLedger"] &&
  alternative[:result_blockers] == [] && alternative[:outbox].map { |row| row[:status] } == %w[refused delivered]
raise "wait status did not reflect blocker" unless first[:cli_status] == { ordinary: 0, waited: 1 } &&
  alternative[:cli_status] == { ordinary: 0, waited: 0 }
puts JSON.pretty_generate({ refusal_first: first, success_first: second,
                            same_aggregate_alternative: alternative })
