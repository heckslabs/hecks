require "spec_helper"

# Runtime::Invocation (roadmap PR I1) — one dispatch as data: verb, target
# (the routing envelope), and every fact as Absent / Null / Present.
# `Invocation.from_call` is now the only reader of a call's shape; the
# interpreters still consume `#to_args`, so I1 changes no behavior.
#
# Fixture constructs and the pinned characterization table, kept out of the
# describe block so they never leak into the global namespace.
module InvocationSpecFixtures
  Attr      = Struct.new(:name, :optional) { def optional? = optional }
  Declaring = Struct.new(:hecks_name, :attributes)
  Operation = Struct.new(:hecks_name, :attributes, :identity, :to) do
    def identity_attribute(_owner_name) = identity
  end
  Aggregate = Struct.new(:hecks_name, :identified_by)

  CREDIT   = Declaring.new("Credit", [Attr.new(:amount, false), Attr.new(:narrative, false), Attr.new(:note, true)])
  ANNOTATE = Declaring.new("Annotate", [Attr.new(:note, false)])
  PAYMENT  = Aggregate.new("Payment", [:payment_id])
  RECEIVE  = Operation.new("Receive", [Attr.new(:amount, false)], nil, nil)
  BY_REF   = Operation.new("Settle", [Attr.new(:payment, false), Attr.new(:amount, false)], Attr.new(:payment, false), nil)
  BY_TO    = Operation.new("Refund", [Attr.new(:payment_id, false), Attr.new(:amount, false)], nil, "Payment")

  # CHARACTERIZATION — every row below was run through the pre-I1 code
  # (`Routing.payload` + `Routing.envelope` for aggregate/entity commands,
  # `Dispatcher#port_invocation` for port operations) and its result pinned
  # here verbatim: the args Hash (as ordered pairs), the envelope, or the
  # refusal class and message. Rows are mined from the BUG# regression specs
  # (routing_envelope_spec, routing_envelope_shape_spec, dry_run's BUG#131,
  # the BUG#16/#17 conformance fixtures, query_null_vo_argument_spec's
  # explicit-null shape) plus each branch's refusal precedence.
  # rubocop:disable Layout/LineLength
  ROWS = [
    ["legacy kwargs only", :aggregate, CREDIT, nil, nil, { account: "a1", amount: 1, narrative: 2 }, 0],
    ["to: + with:", :aggregate, CREDIT, "a1", { amount: 1, narrative: 2 }, {}, 0],
    ["BUG#17 to: beside flat facts, no with:", :aggregate, CREDIT, "a1", nil, { amount: 1, narrative: 2 }, 0],
    ["with: alone", :aggregate, CREDIT, nil, { amount: 1, narrative: 2 }, {}, 0],
    ["BUG#16 to: nil, with: nil, legacy facts", :aggregate, CREDIT, nil, nil, { to: nil, amount: 1, narrative: 2 }, 0],
    ["with: false reads as no with:", :aggregate, CREDIT, "a1", false, { amount: 1, narrative: 2 }, 0],
    ["with: beside loose kwargs", :aggregate, CREDIT, "a1", { amount: 1 }, { narrative: 2 }, 0],
    ["with: a String", :aggregate, CREDIT, "a1", "amount", {}, 0],
    ["with: an Array", :aggregate, CREDIT, "a1", [[:amount, 1]], {}, 0],
    ["with: empty", :aggregate, CREDIT, "a1", {}, {}, 0],
    ["with: unknown and absent", :aggregate, CREDIT, "a1", { zeta: 1, alpha: 2 }, {}, 0],
    ["with: string keys", :aggregate, CREDIT, "a1", { "amount" => 1, "narrative" => 2 }, {}, 0],
    ["with: explicit null required fact", :aggregate, CREDIT, "a1", { amount: nil, narrative: 2 }, {}, 0],
    ["with: explicit null optional fact", :aggregate, CREDIT, "a1", { amount: 1, narrative: 2, note: nil }, {}, 0],
    ["legacy explicit null", :aggregate, CREDIT, nil, nil, { account: "a1", amount: nil, narrative: 2 }, 0],
    ["legacy missing key", :aggregate, CREDIT, nil, nil, { account: "a1", narrative: 2 }, 0],
    ["legacy string keys", :aggregate, CREDIT, nil, nil, { "account" => "a1", "amount" => 1 }, 0],
    ["BUG#7 to: an Integer", :aggregate, CREDIT, -1_267_650_600_228_229_401_496_703_205_376, nil, { name: "r" }, 0],
    ["to: a Symbol", :aggregate, CREDIT, :a1, { amount: 1, narrative: 2 }, {}, 0],
    ["to: blank identity", :aggregate, CREDIT, "", { amount: 1, narrative: 2 }, {}, 0],
    ["BUG#18 to: entities: []", :aggregate, CREDIT, { aggregate: "a1", entities: [] }, { amount: 1, narrative: 2 }, {}, 0],
    ["BUG#18 to: aggregate only", :aggregate, CREDIT, { aggregate: "a1" }, { amount: 1, narrative: 2 }, {}, 0],
    ["to: unrecognized keys", :aggregate, CREDIT, { "aggregate" => "a1", "zz" => 1, "bb" => 2 }, nil, {}, 0],
    ["to: entity and entities", :aggregate, CREDIT, { aggregate: "a1", entity: "e", entities: ["e"] }, nil, {}, 0],
    ["to: Hash blank aggregate", :aggregate, CREDIT, { aggregate: nil, entity: "e" }, nil, {}, 0],
    ["to: Hash with entity on aggregate command", :aggregate, CREDIT, { aggregate: "a1", entity: "e" }, nil, {}, 0],
    ["bad to: + with:/legacy conflict (payload first)", :aggregate, CREDIT, 5, { amount: 1 }, { narrative: 2 }, 0],
    ["BUG#18 with: routing-shaped beside legacy", :aggregate, CREDIT, nil, { aggregate: "a1", entities: [] }, { amount: 1 }, 0],
    ["BUG#131 a fact literally named to", :aggregate, CREDIT, nil, nil, { to: { value: 570 }, name: "r" }, 0],
    ["entity to: Hash entity", :entity, ANNOTATE, { aggregate: "b", entity: "v" }, { note: 1 }, {}, 1],
    ["entity to: Hash entities", :entity, ANNOTATE, { "aggregate" => "b", "entities" => ["v"] }, { note: 1 }, {}, 1],
    ["entity to: scalar", :entity, ANNOTATE, "b", { note: 1 }, {}, 1],
    ["entity to: blank entity", :entity, ANNOTATE, { aggregate: "b", entities: [""] }, { note: 1 }, {}, 1],
    ["entity to: nil entity", :entity, ANNOTATE, { aggregate: "b", entities: [nil] }, { note: 1 }, {}, 1],
    ["entity two hops", :entity, ANNOTATE, { aggregate: "b", entities: %w[v w] }, { note: 1 }, {}, 2],
    ["entity bad to: + conflict (envelope first)", :entity, ANNOTATE, 7, { note: 1 }, { x: 1 }, 1],
    ["entity legacy only", :entity, ANNOTATE, nil, nil, { branch: "b", date: "d", note: 1 }, 1],
    ["entity with: smuggled identity", :entity, ANNOTATE, { aggregate: "b", entity: "v" }, { date: "d", note: 1 }, {}, 1],
    ["entity with: explicit null", :entity, ANNOTATE, { aggregate: "b", entity: "v" }, { note: nil }, {}, 1],
    ["port to: + with:", :port, RECEIVE, "P1", { amount: 1 }, {}, 0],
    ["port missing to:", :port, RECEIVE, nil, { amount: 1 }, {}, 0],
    ["port missing to: + conflict", :port, RECEIVE, nil, { amount: 1 }, { x: 1 }, 0],
    ["port bad to:", :port, RECEIVE, 3, { amount: 1 }, {}, 0],
    ["port to: Hash", :port, RECEIVE, { aggregate: "P1", entity: "x" }, { amount: 1 }, {}, 0],
    ["port legacy", :port, RECEIVE, "P1", nil, { amount: nil }, 0],
    ["port reference attribute lifts into to:", :port, BY_REF, nil, nil, { payment: "P1", amount: 1 }, 0],
    ["port explicit to: wins over reference attribute", :port, BY_REF, "P2", nil, { payment: "P1", amount: 1 }, 0],
    ["port reference lift then with:", :port, BY_REF, nil, { amount: 1 }, { payment: "P1" }, 0],
    ["port null reference attribute lifts nil", :port, BY_REF, nil, nil, { payment: nil, amount: 1 }, 0],
    ["port to:-declared reads identity field", :port, BY_TO, nil, nil, { payment_id: "P1", amount: 1 }, 0],
    ["port to:-declared absent identity field", :port, BY_TO, nil, nil, { amount: 1 }, 0]
  ].freeze

  PRE_I1 = {
    "legacy kwargs only"                              => { args: [[:account, "a1"], [:amount, 1], [:narrative, 2]], target: nil },
    "to: + with:"                                     => { args: [[:amount, 1], [:narrative, 2]], target: ["a1", []] },
    "BUG#17 to: beside flat facts, no with:"          => { args: [[:amount, 1], [:narrative, 2]], target: ["a1", []] },
    "with: alone"                                     => { args: [[:amount, 1], [:narrative, 2]], target: nil },
    "BUG#16 to: nil, with: nil, legacy facts"         => { args: [[:to, nil], [:amount, 1], [:narrative, 2]], target: nil },
    "with: false reads as no with:"                   => { args: [[:amount, 1], [:narrative, 2]], target: ["a1", []] },
    "with: beside loose kwargs"                       => { refusal: ["Hecks::Runtime::TypeMismatch", "dispatch takes command facts in with:, not both with: and loose keyword arguments"] },
    "with: a String"                                  => { refusal: ["Hecks::Runtime::TypeMismatch", "with: must be a hash of command facts"] },
    "with: an Array"                                  => { refusal: ["Hecks::Runtime::TypeMismatch", "with: must be a hash of command facts"] },
    "with: empty"                                     => { refusal: ["Hecks::Runtime::AbsentArgument", "Credit was not given amount, narrative — it takes amount, narrative, note"] },
    "with: unknown and absent"                        => { refusal: ["Hecks::Runtime::UnknownArgument", "Credit does not declare alpha, zeta — it takes amount, narrative, note"] },
    "with: string keys"                               => { args: [[:amount, 1], [:narrative, 2]], target: ["a1", []] },
    "with: explicit null required fact"               => { args: [[:amount, nil], [:narrative, 2]], target: ["a1", []] },
    "with: explicit null optional fact"               => { args: [[:amount, 1], [:narrative, 2], [:note, nil]], target: ["a1", []] },
    "legacy explicit null"                            => { args: [[:account, "a1"], [:amount, nil], [:narrative, 2]], target: nil },
    "legacy missing key"                              => { args: [[:account, "a1"], [:narrative, 2]], target: nil },
    "legacy string keys"                              => { args: [["account", "a1"], ["amount", 1]], target: nil },
    "BUG#7 to: an Integer"                            => { refusal: ["Hecks::Runtime::TypeMismatch", "to: must be a string aggregate identity or an entity route, got -1267650600228229401496703205376"] },
    "to: a Symbol"                                    => { refusal: ["Hecks::Runtime::TypeMismatch", "to: must be a string aggregate identity or an entity route, got :a1"] },
    "to: blank identity"                              => { refusal: ["Hecks::Runtime::TypeMismatch", "to: must name the receiving aggregate identity"] },
    "BUG#18 to: entities: []"                         => { refusal: ["Hecks::Runtime::TypeMismatch", "to: entity route requires at least one entity identity"] },
    "BUG#18 to: aggregate only"                       => { refusal: ["Hecks::Runtime::TypeMismatch", "to: entity route requires at least one entity identity"] },
    "to: unrecognized keys"                           => { refusal: ["Hecks::Runtime::TypeMismatch", "to: does not recognize bb, zz"] },
    "to: entity and entities"                         => { refusal: ["Hecks::Runtime::TypeMismatch", "to: takes entity: or entities:, not both"] },
    "to: Hash blank aggregate"                        => { refusal: ["Hecks::Runtime::TypeMismatch", "to: must name the receiving aggregate identity"] },
    "to: Hash with entity on aggregate command"       => { refusal: ["Hecks::Runtime::TypeMismatch", "to: for an entity command needs 0 entity identities after the aggregate — got 1"] },
    "bad to: + with:/legacy conflict (payload first)" => { refusal: ["Hecks::Runtime::TypeMismatch", "dispatch takes command facts in with:, not both with: and loose keyword arguments"] },
    "BUG#18 with: routing-shaped beside legacy"       => { refusal: ["Hecks::Runtime::TypeMismatch", "dispatch takes command facts in with:, not both with: and loose keyword arguments"] },
    "BUG#131 a fact literally named to"               => { args: [[:to, { value: 570 }], [:name, "r"]], target: nil },
    "entity to: Hash entity"                          => { args: [[:note, 1]], target: ["b", ["v"]] },
    "entity to: Hash entities"                        => { args: [[:note, 1]], target: ["b", ["v"]] },
    "entity to: scalar"                               => { refusal: ["Hecks::Runtime::TypeMismatch", "to: for an entity command needs 1 entity identity after the aggregate — got 0"] },
    "entity to: blank entity"                         => { refusal: ["Hecks::Runtime::TypeMismatch", "to: contains a blank entity identity"] },
    "entity to: nil entity"                           => { refusal: ["Hecks::Runtime::TypeMismatch", "to: contains a blank entity identity"] },
    "entity two hops"                                 => { args: [[:note, 1]], target: ["b", %w[v w]] },
    "entity bad to: + conflict (envelope first)"      => { refusal: ["Hecks::Runtime::TypeMismatch", "to: must be a string aggregate identity or an entity route, got 7"] },
    "entity legacy only"                              => { args: [[:branch, "b"], [:date, "d"], [:note, 1]], target: nil },
    "entity with: smuggled identity"                  => { refusal: ["Hecks::Runtime::UnknownArgument", "Annotate does not declare date — it takes note"] },
    "entity with: explicit null"                      => { args: [[:note, nil]], target: ["b", ["v"]] },
    "port to: + with:"                                => { args: [[:amount, 1]], target: ["P1", []] },
    "port missing to:"                                => { refusal: ["Hecks::Runtime::TypeMismatch", "Receive requires its receiving aggregate in to:"] },
    "port missing to: + conflict"                     => { refusal: ["Hecks::Runtime::TypeMismatch", "Receive requires its receiving aggregate in to:"] },
    "port bad to:"                                    => { refusal: ["Hecks::Runtime::TypeMismatch", "to: must be a string aggregate identity or an entity route, got 3"] },
    "port to: Hash"                                   => { refusal: ["Hecks::Runtime::TypeMismatch", "to: for an entity command needs 0 entity identities after the aggregate — got 1"] },
    "port legacy"                                     => { args: [[:amount, nil]], target: ["P1", []] },
    "port reference attribute lifts into to:"         => { args: [[:amount, 1]], target: ["P1", []] },
    "port explicit to: wins over reference attribute" => { args: [[:payment, "P1"], [:amount, 1]], target: ["P2", []] },
    "port reference lift then with:"                  => { refusal: ["Hecks::Runtime::AbsentArgument", "Settle was not given payment — it takes payment, amount"] },
    "port null reference attribute lifts nil"         => { refusal: ["Hecks::Runtime::TypeMismatch", "Settle requires its receiving aggregate in to:"] },
    "port to:-declared reads identity field"          => { args: [[:payment_id, "P1"], [:amount, 1]], target: ["P1", []] },
    "port to:-declared absent identity field"         => { refusal: ["Hecks::Runtime::TypeMismatch", "Refund requires its receiving aggregate in to:"] }
  }.freeze
  # rubocop:enable Layout/LineLength
end

RSpec.describe Hecks::Runtime::Invocation do
  let(:invocation_class) { described_class }

  def call(receiver, declaring, to: nil, with: nil, legacy: {}, entity_depth: 0)
    invocation_class.from_call("V", to: to, with: with, legacy: legacy, receiver: receiver,
                                    entity_depth: entity_depth, aggregate: InvocationSpecFixtures::PAYMENT) { declaring }
  end

  describe "fact markers" do
    it "has frozen Absent and Null singletons, and a Present carrying its value" do
      expect(described_class::Absent).to be_frozen
      expect(described_class::Null).to be_frozen
      expect(described_class::Present.new(value: 1).value).to eq(1)
    end

    it "freezes facts, even when built from a mutable Hash" do
      facts = { amount: described_class::Present.new(value: 1) }
      invocation = described_class.new(verb: "V", target: nil, facts: facts)

      expect(invocation.facts).to be_frozen
      expect { facts[:other] = described_class::Null }.not_to(change { invocation.facts.size })
    end
  end

  describe ".from_call" do
    it "reads loose keyword arguments: missing key Absent, nil Null, value Present" do
      invocation = call(:aggregate, InvocationSpecFixtures::CREDIT, legacy: { account: "a1", amount: nil })

      expect(invocation.facts[:account]).to eq(described_class::Present.new(value: "a1"))
      expect(invocation.facts[:amount]).to equal(described_class::Null)
      expect(invocation.facts[:narrative]).to equal(described_class::Absent)
      expect(invocation.facts[:note]).to equal(described_class::Absent)
      expect(invocation.target).to be_nil
    end

    it "reads with: the same way, symbolizing its keys" do
      invocation = call(:aggregate, InvocationSpecFixtures::CREDIT, to: "a1", with: { "amount" => 1, "narrative" => nil })

      expect(invocation.present?(:amount)).to be(true)
      expect(invocation.null?(:narrative)).to be(true)
      expect(invocation.absent?(:note)).to be(true)
      expect(invocation.target.aggregate).to eq("a1")
      expect(invocation.target.entities).to eq([])
    end

    it "treats an explicit nil to: exactly like no to: (BUG#16)" do
      expect(call(:aggregate, InvocationSpecFixtures::CREDIT, to: nil, legacy: { amount: 1 }).target).to be_nil
    end

    it "keeps a fact literally named to when to: itself is not given (BUG#131)" do
      invocation = call(:aggregate, InvocationSpecFixtures::CREDIT, legacy: { to: { value: 570 } })

      expect(invocation.value(:to)).to eq(value: 570)
    end

    it "builds an entity route with one identity per hop" do
      route = { aggregate: "b", entities: %w[v w] }
      invocation = call(:entity, InvocationSpecFixtures::ANNOTATE, to: route, with: { note: 1 }, entity_depth: 2)

      expect(invocation.target.entities).to eq(%w[v w])
    end

    it "refuses a blank aggregate identity" do
      expect { call(:aggregate, InvocationSpecFixtures::CREDIT, to: "") }
        .to raise_error(Hecks::Runtime::TypeMismatch, "to: must name the receiving aggregate identity")
    end

    it "refuses a blank entity identity" do
      expect { call(:entity, InvocationSpecFixtures::ANNOTATE, to: { aggregate: "b", entity: "" }, entity_depth: 1) }
        .to raise_error(Hecks::Runtime::TypeMismatch, "to: contains a blank entity identity")
    end

    it "lifts a port operation's reference attribute out of the facts into the target" do
      invocation = call(:port, InvocationSpecFixtures::BY_REF, legacy: { payment: "P1", amount: 1 })

      expect(invocation.target.aggregate).to eq("P1")
      expect(invocation.facts[:payment]).to equal(described_class::Absent)
    end

    it "resolves the declaring construct after to: for an entity, before to: for an aggregate command" do
      entity_order = []
      expect do
        invocation_class.from_call("V", to: 7, with: nil, legacy: {}, receiver: :entity, entity_depth: 1) do
          entity_order << :resolved
          InvocationSpecFixtures::ANNOTATE
        end
      end.to raise_error(Hecks::Runtime::TypeMismatch)
      expect(entity_order).to be_empty

      aggregate_order = []
      expect do
        invocation_class.from_call("V", to: 7, with: nil, legacy: {}) do
          aggregate_order << :resolved
          InvocationSpecFixtures::CREDIT
        end
      end.to raise_error(Hecks::Runtime::TypeMismatch)
      expect(aggregate_order).to eq([:resolved])
    end
  end

  describe "#value" do
    let(:invocation) { call(:aggregate, InvocationSpecFixtures::CREDIT, legacy: { amount: 1, narrative: nil }) }

    it "answers a Present value and nil for Null" do
      expect(invocation.value(:amount)).to eq(1)
      expect(invocation.value(:narrative)).to be_nil
    end

    it "raises KeyError for an Absent fact rather than answering nil" do
      expect { invocation.value(:note) }.to raise_error(KeyError, /V was not given :note/)
      expect { invocation.value(:never_declared) }.to raise_error(KeyError)
    end
  end

  describe "#to_args" do
    it "omits Absent, maps Null to nil, and keeps offered order and key spelling" do
      invocation = call(:aggregate, InvocationSpecFixtures::CREDIT, legacy: { "zeta" => 1, amount: nil, account: "a1" })

      expect(invocation.to_args.to_a).to eq([["zeta", 1], [:amount, nil], [:account, "a1"]])
      expect(invocation.to_args).not_to be_frozen
    end
  end

  describe "characterization against the pre-I1 routing results" do
    def outcome
      invocation = yield
      target = invocation.target
      { args: invocation.to_args.to_a, target: target && [target.aggregate, target.entities] }
    rescue StandardError => e
      { refusal: [e.class.name, e.message] }
    end

    it "covers every pinned row" do
      expect(InvocationSpecFixtures::ROWS.map(&:first)).to match_array(InvocationSpecFixtures::PRE_I1.keys)
    end

    InvocationSpecFixtures::ROWS.each do |label, receiver, declaring, to, with, legacy, depth|
      it "#{label} (#{receiver})" do
        result = outcome { call(receiver, declaring, to: to, with: with, legacy: legacy, entity_depth: depth) }

        expect(result).to eq(InvocationSpecFixtures::PRE_I1.fetch(label))
      end
    end

    it "keeps Routing.payload/.envelope, now delegators, agreeing with from_call" do
      aggregate_rows = InvocationSpecFixtures::ROWS.select { |row| row[1] == :aggregate }
      aggregate_rows.each do |label, _receiver, declaring, to, with, legacy, _depth|
        legacy_result = outcome do
          args  = Hecks::Runtime::Routing.payload(declaring, with: with, legacy: legacy)
          facts = args.transform_values { |v| v.nil? ? described_class::Null : described_class::Present.new(value: v) }
          described_class.new(verb: "V", target: Hecks::Runtime::Routing.envelope(to), facts: facts)
        end

        expect(legacy_result).to eq(InvocationSpecFixtures::PRE_I1.fetch(label)), label
      end
    end
  end
end
