require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"

# A query step is only a test of an adapter when its argument names a row the
# sequence stored. `SequenceGenerator` draws a query's arguments independently
# of the store, so a `where(site_ref: :site_ref)` was asked with a fresh random
# word and matched nothing on every adapter, correct or not. These specs pin
# that a share of query steps takes its arguments from what the sequence wrote,
# that the rest still ask about values nothing stored, and that the choice
# moves no other step.
RSpec.describe Hecks::Fuzzing::SequenceGenerator, ".generate" do
  # The shape a persistence-parity sweep missed: a value object declared on
  # one aggregate (`SiteRef` on `Site`) is the type of an attribute on another
  # (`Deployment`), which has a composite identity and is asked about by it.
  ROLLOUT_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Rollout" do
      vision "deployments asked about by the site they belong to"
      core

      aggregate "Site" do
        description "a site"
        identified_by :reference

        value_object "SiteRef" do
          attribute :value, String
          invariant("a site is referenced") { !value.to_s.empty? }
        end

        attribute :reference, SiteRef

        command "Register" do
          role "Operator"
          goal "register a site"
          attribute :reference, SiteRef
          sets :reference
          emits "SiteRegistered"
        end
      end

      aggregate "Deployment" do
        description "one deploy attempt against one site"
        identified_by :site_ref, :requested_at

        value_object "Stamp" do
          attribute :value, String
          invariant("a stamp is present") { !value.to_s.empty? }
        end

        attribute :site_ref,      SiteRef
        attribute :requested_at,  Stamp

        command "Request" do
          role "Operator"
          goal "ask for a deploy"
          attribute :site_ref,     SiteRef
          attribute :requested_at, Stamp
          sets :site_ref
          sets :requested_at
          emits "DeploymentRequested"
        end

        query "ForSite" do
          description "every deploy attempt for one site"
          attribute :site_ref, SiteRef
          where(site_ref: :site_ref)
        end

        query "ForSiteAt" do
          description "the one attempt for a site at a time"
          attribute :site_ref,     SiteRef
          attribute :requested_at, Stamp
          where(site_ref: :site_ref)
          where(requested_at: :requested_at)
        end
      end
    end
  BLUEBOOK

  def seeds = (1..12).to_a

  def steps_per_sequence = 30

  around do |example|
    Dir.mktmpdir("query-binding") do |root|
      FileUtils.mkdir_p(File.join(root, "rollout"))
      File.write(File.join(root, "rollout", "rollout.bluebook"), ROLLOUT_BLUEBOOK)
      @domain = File.join(root, "rollout")
      example.run
    end
  end

  def generate(seed, **) = described_class.generate(@domain, seed: seed, steps: steps_per_sequence, **)

  def query?(step, name) = step["query"].to_s.end_with?(".#{name}")

  # Every query step of `name` across `seeds`, with the rows Memory answered.
  def answered(name, **options)
    seeds.flat_map do |seed|
      steps   = generate(seed, **options)
      queries = Hecks::Fuzzing::Replay.call(@domain, steps, adapter: :memory)[:queries]
      queries.select { |asked| asked[:query].to_s.end_with?(".#{name}") }
    end
  end

  it "asks about a value the sequence stored, so the query answers rows" do
    hits = answered("ForSite").count { |asked| Array(asked[:rows]).any? }

    expect(hits).to be >= 10
  end

  it "still asks about values nothing stored, so the query also answers empty" do
    misses = answered("ForSite").count { |asked| Array(asked[:rows]).empty? }

    expect(misses).to be >= 5
  end

  it "takes every parameter of one query from the same stored record" do
    hits = answered("ForSiteAt").count { |asked| Array(asked[:rows]).any? }

    expect(hits).to be >= 10
  end

  it "changes the arguments of query steps and no other step" do
    with_binding = seeds.to_h { |seed| [seed, generate(seed, adversarial: 0.3)] }
    stub_const("Hecks::Fuzzing::SequenceGenerator::QueryBinding::BOUND_QUERY_PROBABILITY", 0.0)
    without_binding = seeds.to_h { |seed| [seed, generate(seed, adversarial: 0.3)] }

    seeds.each do |seed|
      expect(with_binding[seed].reject { |step| step.key?("query") })
        .to eq(without_binding[seed].reject { |step| step.key?("query") })
    end
    expect(with_binding).not_to eq(without_binding)
  end

  it "binds queries the same way for the same seed" do
    first  = generate(3)
    second = generate(3)

    expect(first).to eq(second)
  end

  it "keeps a step's arguments in the JSON shape a corpus carries" do
    steps = seeds.flat_map { |seed| generate(seed) }

    expect(steps.select { |step| step.key?("query") }).to all(satisfy { |step| step["args"].is_a?(Hash) })
    expect(JSON.parse(JSON.generate(steps))).to eq(steps)
  end
end
