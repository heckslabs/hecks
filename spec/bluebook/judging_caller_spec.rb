require "spec_helper"
require "hecks/corpus"
require "hecks/runtime/role_shadow/gated_verbs"
require "hecks/tools/model_check"

# The judge offers a loaded bluebook to bluebook.bluebook, whose every role-gated command declares
# `role "Language"`; the world, port, adapter and translation judges offer theirs to languages
# that declare `role "Deployment"`. Each states its language's role, so under `enforce` a load is
# never refused for the caller around it (ADR 0216), and the same load refuses when it states none.
RSpec.describe Hecks::Bluebook::MetaValidator::JudgingCaller do
  def validator = Hecks::Bluebook::MetaValidator

  def language = validator.grammar_registry.bluebook("Bluebook")

  def unstated(&) = Hecks::Runtime::Caller.unstated(&)

  # The roles the role-gated commands of one language bluebook declare.
  def declared_roles(name)
    Hecks::Runtime::RoleShadow::GatedVerbs.new([validator.grammar_registry.bluebook(name)]).gated.values.flatten.uniq
  end

  # Every load judged afresh: no verdict from this process or from disk answers it.
  def with_fresh_verdicts
    kept = validator.verdicts
    cache = ENV.fetch("HECKS_VERDICT_CACHE", nil)
    ENV["HECKS_VERDICT_CACHE"] = "off"
    validator.instance_variable_set(:@verdicts, {})
    yield
  ensure
    ENV["HECKS_VERDICT_CACHE"] = cache
    validator.instance_variable_set(:@verdicts, kept)
  end

  # The language built again from its files, as the first load of a process builds it; the
  # memoized one is put back after.
  def with_fresh_grammar(&)
    saved = %i[@grammar_registry @grammar_ready_for].to_h { |ivar| [ivar, validator.instance_variable_get(ivar)] }
    saved.each_key { |ivar| validator.instance_variable_set(ivar, nil) }
    with_fresh_verdicts(&)
  ensure
    saved&.each { |ivar, value| validator.instance_variable_set(ivar, value) }
  end

  # The refusals for the caller a corpus load met, one line per source that met one.
  def corpus_role_refusals
    sources = Hecks::Corpus.model_check_members.filter_map { |member| Hecks::Corpus.source_of(member) }
    sources.filter_map do |source|
      Hecks::Tools::ModelCheck.boot(source)
      nil
    rescue Hecks::Runtime::Unauthorized => e
      "#{source}: #{e.message}"
    end
  end

  # The first corpus world, loaded as its own judge loads it.
  def corpus_world
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks::ClosedForm.load_file(Hecks::Corpus.world_files.first) }
    registry.worlds.values.first
  end

  def world_role_refusals
    Hecks::Corpus.world_files.filter_map do |file|
      Hecks.with_registry(Hecks::Runtime::Registry.new) { Hecks::ClosedForm.load_file(file) }
      nil
    rescue Hecks::Runtime::Unauthorized => e
      "#{file}: #{e.message}"
    end
  end

  around do |example|
    mode = Hecks::Runtime::RoleShadow.mode
    Hecks::Runtime::RoleShadow.install(:enforce)
    example.run
  ensure
    Hecks::Runtime::RoleShadow.install(mode)
  end

  it "states the role every role-gated command of each language it judges declares", :aggregate_failures do
    expect(declared_roles("Bluebook")).to eq([Hecks::Bluebook::MetaValidator::Judge::ROLE])
    { "World" => "WorldJudge", "Port" => "PortJudge", "Adapter" => "AdapterJudge",
      "Translation" => "TranslationJudge" }.each do |name, judge|
      expect(declared_roles(name)).to eq([Hecks::Bluebook::MetaValidator.const_get(judge)::ROLE])
    end
  end

  it "builds the language from bluebook.bluebook for a caller who stated no role" do
    built = with_fresh_grammar { unstated { validator.grammar_registry.bluebook("Bluebook") } }
    expect(built.aggregates.map(&:name)).to include("Bluebook", "Aggregate", "Command")
  end

  it "judges bluebook.bluebook through itself for a caller who stated no role" do
    held = with_fresh_verdicts { unstated { validator.hold(language) } }
    expect(held[:refusals]).to be_empty
  end

  it "judges bluebook.bluebook through itself for a launcher line that states another role" do
    held = with_fresh_verdicts { Hecks::Runtime::Caller.as(role: "Maintainer") { validator.hold(language) } }
    expect(held[:refusals]).to be_empty
  end

  it "loads every corpus bluebook and its wiring through the judge for a caller who stated no role" do
    expect(with_fresh_verdicts { unstated { corpus_role_refusals } }).to eq([])
  end

  it "loads every corpus world through the world judge for a caller who stated no role" do
    expect(with_fresh_verdicts { unstated { world_role_refusals } }).to eq([])
  end

  it "refuses the judge's load of bluebook.bluebook when the load itself states no role" do
    expect { unstated { Hecks::Bluebook::MetaValidator::Judge.new(language) } }
      .to raise_error(Hecks::Runtime::Unauthorized, "Declare refused — role: Language, and the caller stated no role")
  end

  it "refuses the world judge's load when the load itself states no role" do
    world = corpus_world
    expect { unstated { Hecks::Bluebook::MetaValidator::WorldJudge.new(world) } }
      .to raise_error(Hecks::Runtime::Unauthorized, "Declare refused — role: Deployment, and the caller stated no role")
  end
end
