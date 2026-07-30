require "spec_helper"

# Every where-clause comparator the language declares (Vocabulary::QueryComparator)
# and the DSL admits (QuerySpecification::Common::COMPARATORS), exercised at
# least once. Nothing in the real corpus uses gt/gte/lte/ne/in/contains — they
# were silently treated as `eq` in both Runtime::QueryInterpreter#holds? and
# Ports::Query::InMemory#holds? until this spec's fixture existed to catch it.
RSpec.describe "where-clause comparators" do
  FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/query_ops.bluebook")

  def boot
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(FIXTURE)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  def seed(runtime)
    runtime.dispatch("QueryOps::Item.Add", label: { value: "a" }, amount: { value: 3 },
                                           status: { value: "open" },    tags: [{ value: "urgent" }])
    runtime.dispatch("QueryOps::Item.Add", label: { value: "b" }, amount: { value: 10 },
                                           status: { value: "closed" },  tags: [{ value: "later" }])
    runtime.dispatch("QueryOps::Item.Add", label: { value: "c" }, amount: { value: 5 },
                                           status: { value: "pending" }, tags: [])
    runtime
  end

  def labels(rows) = rows.map { |r| r[:label].value }

  {
    "Eq"       => %w[a],
    "Ne"       => %w[b c],
    "Gt"       => %w[b],
    "Gte"      => %w[b c],
    "Lt"       => %w[a],
    "Lte"      => %w[a c],
    "In"       => %w[a c],
    "Contains" => %w[a]
  }.each do |query_name, expected|
    it "#{query_name} matches #{expected.join(', ')}" do
      runtime = seed(boot)
      expect(labels(runtime.query("QueryOps::Item.#{query_name}"))).to match_array(expected)
    end
  end
end
