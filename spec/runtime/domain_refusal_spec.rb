require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/postgres_probe"

# A refusal is the domain saying no; anything else is the runtime breaking.
# Every error the corpus provokes must be in `Runtime::DOMAIN_REFUSALS`, so a crash
# is never recorded as a refusal.
RSpec.describe "every refusal the corpus provokes" do
  CORPUS = {
    "banking" => "examples/banking",
    "pizzas"  => "examples/pizzas"
  }.freeze

  def domain_refusal?(error)
    Hecks::Runtime::DOMAIN_REFUSALS.any? { |klass| error.is_a?(klass) }
  end

  CORPUS.each do |name, path|
    # Copying the tree isolates the Heki-backed "banking" store, but "pizzas" declares
    # `persisted_by("PostgresEra")` with a fixed connection string and still boots against the
    # shared database, so only "pizzas" is `io: true` and skips without Postgres.
    it "#{name} raises only errors the domain is allowed to raise",
       io: (name == "pizzas") do
      skip "no reachable Postgres — start one to run this spec" if name == "pizzas" && !PostgresProbe.available?

      script = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/#{name}.json")))
      Dir.mktmpdir do |tmp|
        domain = File.join(tmp, name)
        # Skip data/: parallel workers boot the example in place; Heki renames its .tmp mid-copy.
        source = File.join(InMemoryDomain::ROOT, path)
        FileUtils.mkdir_p(domain)
        (Dir.children(source) - ["data"]).each { |child| FileUtils.cp_r(File.join(source, child), domain) }
        runtime = Hecks.boot(domain)

        faults = []
        script.fetch("steps").each do |step|
          args = (step["args"] || {}).transform_keys(&:to_sym)
          begin
            if (question = step["query"])
              runtime.query(question, **args)
            else
              runtime.dispatch_flat(step["verb"], **args)
            end
          rescue StandardError => e
            verb_or_query = step.key?("verb") ? step["verb"] : step["query"]
            faults << "#{verb_or_query} raised #{e.class}: #{e.message}" unless domain_refusal?(e)
          end
        end

        expect(faults).to be_empty
      end
    end
  end

  it "catches an error the domain is NOT allowed to raise" do
    # The guard must be seen rejecting something, or it cannot be trusted to fire.
    error = Hecks::Bluebook::Expression::EvaluationError.new("a predicate blew up")
    expect(domain_refusal?(error)).to be(false)
    expect(domain_refusal?(Hecks::Runtime::TypeMismatch.new("a value was wrong"))).to be(true)
  end
end
