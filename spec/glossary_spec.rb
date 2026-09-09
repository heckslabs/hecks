require "spec_helper"

# THE GLOSSARY EVERY DOMAIN CARRIES WITH IT — `examples/<domain>/glossary/`
# is a projection of the bluebook beside it, and this refuses a diff the
# same way spec/diagrams_spec.rb refuses one for the diagrams: regenerate
# in memory, compare byte for byte, refuse an orphan. The page is then
# checked for the three promises Projections::Glossary makes to a reader
# outside engineering — no identifiers, no type labels, every link lands.
RSpec.describe "the glossary a domain carries with it" do
  DOMAINS = { "pizzas" => "Pizzas", "banking" => "Banking" }.freeze

  def chapter_of(domain, name)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      InMemoryDomain.load_bluebook_files(File.join(InMemoryDomain::ROOT, "examples", domain, "bluebook"))
    end
    registry.bluebook(name)
  end

  def committed_dir(domain) = File.join(InMemoryDomain::ROOT, "examples", domain, "glossary")

  def committed_files(domain)
    Dir.glob("**/*", base: committed_dir(domain)).select { |path| File.file?(File.join(committed_dir(domain), path)) }
  end

  DOMAINS.each do |domain, name|
    describe domain do
      let(:chapter) { chapter_of(domain, name) }
      let(:tree)    { Hecks::Projector.call(:glossary, bluebook: chapter) }
      let(:html)    { File.read(File.join(committed_dir(domain), "html/index.html")) }
      let(:visible) { html.gsub(%r{<(script|style)[^>]*>.*?</\1>}m, "").gsub(/<[^>]+>/, " ") }

      it "is exactly what bin/project_glossary would regenerate right now" do
        expect(tree.keys).to contain_exactly("glossary.md", "html/index.html")
        tree.each do |relative, contents|
          path = File.join(committed_dir(domain), relative)
          expect(File).to exist(path), "#{domain}/glossary/#{relative} is missing — run bin/project_glossary"
          expect(File.read(path)).to eq(contents),
                                     "#{domain}/glossary/#{relative} is stale — run bin/project_glossary and commit it"
        end
        expect(committed_files(domain).sort).to eq(tree.keys.sort)
      end

      it "renders the page from the Markdown, so the two cannot drift" do
        markdown = File.read(File.join(committed_dir(domain), "glossary.md"))
        expect(Hecks::Projections::Glossary::Html.render(markdown)).to eq(html)
      end

      it "spells every headword as a person would, never as an identifier" do
        headwords = tree["glossary.md"].scan(/^\#{2,3} (.+)$/).flatten
        expect(headwords).not_to be_empty
        expect(headwords.grep(/[a-z][A-Z]/)).to be_empty
      end

      it "names no kinds — a term is just a term" do
        expect(visible).not_to match(/\b(Aggregate|Value Object|Read Model|Lifecycle|Saga)\b/)
      end

      it "lands every in-page link on a heading" do
        ids   = html.scan(/ id="([^"]+)"/).flatten
        hrefs = html.scan(/ href="#([^"]+)"/).flatten
        expect(hrefs).not_to be_empty
        expect(hrefs - ids).to be_empty
      end

      it "fetches nothing but its typefaces and the diagram renderer" do
        external = html.scan(/(?:src|href)="(https?:[^"]+)"/).flatten
        expect(external.map { |url| URI(url).host }.uniq).to contain_exactly("fonts.googleapis.com", "cdnjs.cloudflare.com")
      end

      it "draws the map, one picture per aggregate, and one per lifecycle" do
        holders = chapter.aggregates
        expect(html.scan('class="mermaid"').size).to eq(1 + holders.size + holders.count(&:lifecycle))
      end
    end
  end

  describe "banking, read closely" do
    let(:markdown) { File.read(File.join(committed_dir("banking"), "glossary.md")) }
    let(:html)     { File.read(File.join(committed_dir("banking"), "html/index.html")) }

    it "tells Open the action from Open the list by qualifying the headword, not numbering it" do
      expect(markdown).to include("### Open\n", "### Open (the list)\n")
      expect(markdown).not_to match(/^### Open \(\d\)/)
    end

    it "shows the reader ATM card, not ATMCard, in the rail" do
      expect(html).to include(">ATM card</a>")
      expect(html).not_to include("ATMCard")
    end

    it "keeps a rule out of the definition and on its own line" do
      expect(markdown).to include("### Money\n\nMade up of cents (a whole number) and currency (text).\n\n" \
                                  "Always true: a currency is a three-letter code.")
    end

    it "says who reacts to an event, in words, with a link" do
      expect(markdown).to include("Recorded after [Freeze account](#freeze-account). " \
                                  "Prompts [Review on freeze](#review-on-freeze).")
    end

    it "speaks a cross-domain trigger as words, since there is nothing here to link to" do
      expect(markdown).to include("Account freeze review is asked to open, in Compliance.")
    end
  end

  describe "pizzas, whose one reaction is raised by a port" do
    it "keeps that reaction visible in its own section rather than dropping it" do
      markdown = File.read(File.join(committed_dir("pizzas"), "glossary.md"))
      expect(markdown).to include("## Reactions", "### On pizza payment received")
    end
  end
end
