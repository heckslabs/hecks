require "spec_helper"
require "hecksagain/interview"
require "tmpdir"

# THE ACCEPTANCE TEST FOR `Interview::Source`, not a unit test of it.
#
# Render every real corpus member from its OWN reconstruction (the exact
# path `Interview::Session#declaration` takes — `MetaValidator.hold`, then
# `Reconstruction.of`), load the rendered text back into a fresh, isolated
# registry, and compare the reloaded bluebook's `to_h` against the
# ORIGINAL bluebook's own `to_h` — not the reconstruction, the real thing
# a plain `Kernel.load` of the corpus file itself produces. If banking
# (1541 lines: composite identity, entities, closed sets, sagas, a read
# model) comes back byte-for-byte equal, the renderer is real rather than
# merely plausible on paper.
#
# DERIVED THE SAME WAY spec/corpus_spec.rb DERIVES ITS OWN CORPUS, not a
# second hand-kept list — a member added there is covered here too, with
# nobody needing to remember a second file.
RSpec.describe "Interview::Source, rendering the corpus back to source" do
  def self.bluebook_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.bluebook")).sort.first ||
      Dir.glob(File.join(domain, "*.bluebook")).sort.first
  end

  # PREFIXED, ALL FOUR — a plain `EXAMPLE_ROOTS` here collides with
  # `corpus_spec.rb`'s own constant of the same name: a `describe` block
  # is `instance_eval`'d, but a bare constant assignment inside one still
  # lands at the TOP LEVEL regardless (a real Ruby gotcha, not an RSpec
  # one), so two spec files declaring the identical name land in the
  # same global namespace the moment both load in one process. Caught by
  # `spec/load_hygiene_spec.rb`'s own "no two spec files disagree about a
  # top-level constant" gate — measured, not a guess taken up front.
  RENDER_GATE_EXAMPLE_ROOTS = Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*"))
                                  .select { |path| File.directory?(path) }.sort.freeze
  RENDER_GATE_GRAMMAR_CHAPTERS =
    Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecksagain/grammar", "*.bluebook")).sort.freeze
  RENDER_GATE_FRAMEWORK_MEMBERS =
    Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecksagain/framework/bluebook", "*.bluebook")).sort.freeze

  RENDER_GATE_CORPUS_MEMBERS = (
    RENDER_GATE_EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebook_in(domain)] } +
    RENDER_GATE_GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
    RENDER_GATE_FRAMEWORK_MEMBERS.map { |member| [File.basename(member, ".bluebook"), member] }
  ).reject { |_, source| source.nil? }.freeze

  def boot(path)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(path)
    end
    registry.bluebooks.values.first
  end

  RENDER_GATE_CORPUS_MEMBERS.each do |name, source|
    it "renders #{name} from its own reconstruction, and the reload matches the original bit for bit" do
      original = boot(source)
      held = Hecksagain::Bluebook::MetaValidator.hold(original)
      expect(held[:refusals]).to be_empty, "the meta-domain itself refused #{name}: #{held[:refusals].join('; ')}"

      text = Hecksagain::Interview::Source.render(held[:declaration])

      Dir.mktmpdir do |dir|
        path = File.join(dir, "#{name}.bluebook")
        File.write(path, text)

        reloaded = nil
        expect { reloaded = boot(path) }.not_to raise_error, -> { "rendered #{name} does not even load:\n#{text}" }
        expect(reloaded.to_h).to eq(original.to_h),
                                 "#{name} round-tripped but does not match — rendered text:\n#{text}"
      end
    end
  end
end
