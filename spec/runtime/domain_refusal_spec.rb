
require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/postgres_probe"

# A refusal is the domain saying NO. Anything else is the runtime breaking.
#
# `Runtime::DOMAIN_REFUSALS` declares that boundary, and the policy and saga
# interpreters honour it — they rescue only those classes, so a crash in a
# reaction propagates instead of being logged as "declined". The RUNNER did
# not: `bin/run` catches everything a dispatch throws and
# writes it into `refusals`, so a crash arrives in the run contract wearing a
# refusal's clothes.
#
# That is not hypothetical. Every one of these was recorded as a refusal:
#
#   positive? expects a number, got {"value":3}     the append flatten bug
#   no implicit conversion of Symbol into Integer   an argument/attribute collision
#   addition expects a number, got "a lot"          a String reaching a numeric field
#
# The last is fixed at the source — `Value.check_numeric_fields` now refuses it
# as a TypeMismatch, which IS a domain refusal. This spec is what stops the
# class from coming back: every error the corpus provokes must be one the
# domain is allowed to raise.
RSpec.describe "every refusal the corpus provokes" do
  CORPUS = {
    "banking" => "examples/banking",
    "pizzas"  => "examples/pizzas"
  }.freeze

  def domain_refusal?(error)
    Hecksagain::Runtime::DOMAIN_REFUSALS.any? { |klass| error.is_a?(klass) }
  end

  CORPUS.each do |name, path|
    # `rm_rf(data/)` isolates a Heki-backed copy ("banking") for real —
    # copying the DIRECTORY copies the store, and wiping `data/` resets
    # it. It isolates nothing for "pizzas": examples/pizzas' own .world
    # declares `persisted_by("Postgres")` unconditionally (a fixed
    # connection string, not a path inside the copied tree — see
    # support/postgres_probe.rb's own note), so the copy still boots
    # against the real, shared hecks_pizzas database. `io: true` and
    # self-skipping otherwise, same as every other real-Postgres spec —
    # only for "pizzas"; "banking" stays a plain, always-runs example.
    it "#{name} raises only errors the domain is allowed to raise",
       io: (name == "pizzas"),
       skip: (name == "pizzas" && !PostgresProbe::AVAILABLE ? "no reachable Postgres — start one to run this spec" : false) do
      script = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/#{name}.json")))
      Dir.mktmpdir do |tmp|
        domain = File.join(tmp, name)
        FileUtils.cp_r(File.join(InMemoryDomain::ROOT, path), domain)
        FileUtils.rm_rf(File.join(domain, "data"))
        runtime = Hecks.boot(domain)

        faults = []
        script.fetch("steps").each do |step|
          args = (step["args"] || {}).transform_keys(&:to_sym)
          begin
            if (question = step["query"])
              runtime.query(question, **args)
            else
              runtime.dispatch(step["verb"], **args)
            end
          rescue StandardError => e
            faults << "#{step['verb'] || step['query']} raised #{e.class}: #{e.message}" unless domain_refusal?(e)
          end
        end

        expect(faults).to be_empty
      end
    end
  end

  it "catches an error the domain is NOT allowed to raise" do
    # The guard has to be seen refusing something, or it is one more rule that
    # cannot fire. EvaluationError is the class the three leaks above wore.
    error = Hecksagain::Bluebook::Expression::EvaluationError.new("a predicate blew up")
    expect(domain_refusal?(error)).to be(false)
    expect(domain_refusal?(Hecksagain::Runtime::TypeMismatch.new("a value was wrong"))).to be(true)
  end
end
