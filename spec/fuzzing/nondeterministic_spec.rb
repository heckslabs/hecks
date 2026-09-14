require "spec_helper"
require "hecks/fuzzing"

# `Hecks::Fuzzing::Nondeterministic` is a partition, not a filter: a field
# leaves a comparison only by being declared there, with its reason. These
# examples keep that true in both directions — no call site re-derives its
# own except-list, and no declared field outlives the thing that produced it.
RSpec.describe Hecks::Fuzzing::Nondeterministic do
  NONDETERMINISTIC_ROOT     = InMemoryDomain::ROOT
  NONDETERMINISTIC_PIZZAS   = File.join(NONDETERMINISTIC_ROOT, "examples/pizzas")
  NONDETERMINISTIC_FUZZ_DIR = File.join(NONDETERMINISTIC_ROOT, "lib/hecks/fuzzing")
  NONDETERMINISTIC_HOME     = File.join(NONDETERMINISTIC_FUZZ_DIR, "nondeterministic.rb")

  # Where each group's fields ride in a real `Replay.call` history — one
  # locator per group, so a new group with nowhere to look fails below.
  NONDETERMINISTIC_LOCATORS = {
    query_row:  ->(history) { history[:queries] },
    outbox_row: ->(history) { Array(history[:outbox_traces]).flat_map { |trace| trace[:rows] } },
    event:      ->(history) { Array(history[:outbox_traces]).flat_map { |trace| trace[:rows].map { |row| row[:event] } } },
    history:    ->(history) { [history] }
  }.freeze

  it "gives every declared field a non-empty reason" do
    described_class::FIELDS.each do |group, fields|
      fields.each do |name, reason|
        expect(reason.to_s.strip).not_to be_empty, "#{group}.#{name} has no reason"
      end
    end
  end

  it "has no literal except-list of a declared field anywhere else under lib/hecks/fuzzing" do
    names = described_class.all_names.map(&:to_s)
    files = Dir[File.join(NONDETERMINISTIC_FUZZ_DIR, "**/*.rb")] - [NONDETERMINISTIC_HOME]
    offenders = files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        next if line.lstrip.start_with?("#")

        listed = line.scan(/\.except\(([^)]*)\)/).flatten.join(" ")
        hit = names.find { |name| listed.match?(/(?::|["'])#{Regexp.escape(name)}\b/) }
        "#{file.delete_prefix("#{NONDETERMINISTIC_ROOT}/")}:#{index + 1} excludes #{hit}" if hit
      end
    end

    expect(offenders).to be_empty,
                         "declare these in Hecks::Fuzzing::Nondeterministic::FIELDS and strip by group:\n" \
                         "#{offenders.join("\n")}"
  end

  it "has a locator for exactly the declared groups" do
    expect(NONDETERMINISTIC_LOCATORS.keys).to match_array(described_class::FIELDS.keys)
  end

  # Banking's account opening enqueues real outbox rows (its `Onboarding`
  # saga listens on `AccountOpened` — spec/fuzzing/properties/outbox_spec.rb
  # pins the same scenario); pizzas' generated sequences reach its queries.
  def banking_outbox_steps
    [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => "NDT-CUST" }, "name" => { "given" => "Ada", "family" => "Lovelace" },
                    "email" => { "address" => "ada@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => "NDT-ACCT" }, "kind" => { "name" => "current" },
                    "daily_limit" => { "cents" => 50_000 }, "customer" => "NDT-CUST" } }
    ]
  end

  # A stale tolerance fails: every declared field must actually appear, on
  # its declared shape, in a real replayed history.
  it "declares only fields a real replay actually produces" do
    histories = (1..5).map do |seed|
      steps = Hecks::Fuzzing::SequenceGenerator.generate(NONDETERMINISTIC_PIZZAS, seed: seed, steps: 25)
      Hecks::Fuzzing::Replay.call(NONDETERMINISTIC_PIZZAS, steps)
    end
    histories << Hecks::Fuzzing::Replay.call(File.join(NONDETERMINISTIC_ROOT, "examples/banking"), banking_outbox_steps)

    described_class::FIELDS.each do |group, fields|
      shapes = histories.flat_map { |history| NONDETERMINISTIC_LOCATORS.fetch(group).call(history) }.compact
      fields.each_key do |name|
        expect(shapes.any? { |shape| shape.key?(name) }).to be(true),
                                                            "#{group}.#{name} is declared nondeterministic but no " \
                                                            "replayed history produced it — a stale tolerance"
      end
    end
  end

  it "strips exactly one group's fields and nothing else" do
    row = { query: "Available", rows: [], instances_at: {}, event_uid: "kept" }

    expect(described_class.strip(row, :query_row)).to eq(query: "Available", rows: [], event_uid: "kept")
  end
end
