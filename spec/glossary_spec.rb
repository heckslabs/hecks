require "spec_helper"

# Each committed `<domain>/glossary/` must match a fresh in-memory projection byte for byte,
# with no orphan files, and the page must keep the Glossary promises: no identifiers or kinds.
RSpec.describe "the glossary a domain carries with it" do
  # Domain folder (relative to the repo root) => the bluebook it declares.
  GLOSSARY_DOMAINS = {
    "examples/pizzas"  => "Pizzas",
    "examples/banking" => "Banking",
    "qa"               => "QualityControl"
  }.freeze

  def bluebook_of(domain, name)
    # Loaded as `hecks glossary` loads it, wiring included, but with no adapter bound: verifying
    # the wiring resolves each policy's ask to the port it names, and `qa`'s ledger would
    # otherwise need its database.
    registry = Hecks.describe(File.join(InMemoryDomain::ROOT, domain), environment: nil).registry
    registry.verify!
    registry.bluebook(name)
  end

  def committed_dir(domain) = File.join(InMemoryDomain::ROOT, domain, "glossary")

  def committed_files(domain)
    Dir.glob("**/*", base: committed_dir(domain)).select { |path| File.file?(File.join(committed_dir(domain), path)) }
  end

  GLOSSARY_DOMAINS.each do |domain, name|
    describe File.basename(domain) do
      let(:declaration) { bluebook_of(domain, name) }
      let(:tree)    { Hecks::Projector.call(:glossary, bluebook: declaration) }
      let(:html)    { File.read(File.join(committed_dir(domain), "html/index.html")) }
      let(:visible) { html.gsub(%r{<(script|style)[^>]*>.*?</\1>}m, "").gsub(/<[^>]+>/, " ") }

      it "carries exactly the files hecks glossary would write", :aggregate_failures do
        expect(tree.keys).to contain_exactly("glossary.md", "html/index.html")
        expect(committed_files(domain).sort).to eq(tree.keys.sort)
      end

      it "is exactly what hecks glossary would regenerate right now", :aggregate_failures do
        tree.each do |relative, contents|
          path = File.join(committed_dir(domain), relative)
          expect(File).to exist(path), "#{domain}/glossary/#{relative} is missing — run hecks glossary"
          expect(File.read(path)).to eq(contents), "#{domain}/glossary/#{relative} is stale — run hecks glossary and commit it"
        end
      end

      it "renders the page from the Markdown, so the two cannot drift" do
        markdown = File.read(File.join(committed_dir(domain), "glossary.md"))
        expect(Hecks::Projections::Glossary::Html.render(markdown)).to eq(html)
      end

      it "spells every headword as a person would, never as an identifier", :aggregate_failures do
        headwords = tree["glossary.md"].scan(/^\#{2,4} (.+)$/).flatten
        expect(headwords).not_to be_empty
        expect(headwords.grep(/[a-z][A-Z]/)).to be_empty
      end

      it "names no kinds — a term is just a term" do
        expect(visible).not_to match(/\b(Aggregate|Value Object|Read Model|Lifecycle|Saga)\b/)
      end

      it "lands every in-page link on a heading", :aggregate_failures do
        ids   = html.scan(/ id="([^"]+)"/).flatten
        hrefs = html.scan(/ href="#([^"]+)"/).flatten
        expect(hrefs).not_to be_empty
        expect(hrefs - ids).to be_empty
      end

      it "fetches nothing but its typefaces and the diagram renderer" do
        external = html.scan(/(?:src|href)="(https?:[^"]+)"/).flatten
        expect(external.map { |url| URI(url).host }.uniq).to contain_exactly("fonts.googleapis.com", "cdnjs.cloudflare.com")
      end

      it "draws the map when there is more than one thing, each thing with neighbours, and each lifecycle" do
        holders = declaration.aggregates
        fitting = holders.count { |holder| Hecks::Projections::Glossary::Mermaid.neighbours?(holder, declaration) }
        expect(html.scan('class="mermaid"').size).to eq((holders.size > 1 ? 1 : 0) + fitting + holders.count(&:lifecycle))
      end
    end
  end

  describe "banking, read closely" do
    let(:markdown) { File.read(File.join(committed_dir("examples/banking"), "glossary.md")) }
    let(:html)     { File.read(File.join(committed_dir("examples/banking"), "html/index.html")) }

    it "tells Open the action from Open the list by qualifying the headword, not numbering it", :aggregate_failures do
      expect(markdown).to include("#### Open\n", "#### Open (the list)\n")
      expect(markdown).not_to match(/^#### Open \(\d\)/)
    end

    it "shows the reader ATM card, not ATMCard, in the rail", :aggregate_failures do
      expect(html).to include(">ATM card</a>")
      expect(html).not_to include("ATMCard")
    end

    it "keeps a rule out of the definition and on its own line" do
      expect(markdown).to include("#### Money\n\nMade up of cents (a whole number) and currency (text).\n\n" \
                                  "Always true: a currency is a three-letter code.")
    end

    it "says who reacts to an event, in words, with a link" do
      expect(markdown).to include("Recorded after [Freeze account](#freeze-account). " \
                                  "Prompts [Review on freeze](#review-on-freeze).")
    end

    it "speaks a cross-domain trigger as words, since there is nothing here to link to" do
      expect(markdown).to include("Review is asked to open, in Compliance.")
    end
  end

  PIZZAS_PURCHASE_TERM = "#### Purchase\n\nBuy the pizza. Done by the customer.\n\n" \
                         "Needs an amount ([Price](#price)) and a customer name " \
                         "([Customer name](#customer-name), optional).\n\n" \
                         "Allowed only when: the order is available; a pizza needs at least one topping; " \
                         "a payment was actually made; the payment covers the price.\n\n" \
                         "Sets the customer name and moves the order from available to sold.\n\n" \
                         "Records [Pizza purchased](#pizza-purchased).".freeze

  describe "pizzas, read as a reviewer would" do
    let(:markdown) { File.read(File.join(committed_dir("examples/pizzas"), "glossary.md")) }

    it "keeps the reaction a port raises visible in its own section rather than dropping it" do
      expect(markdown).to include("## Reactions", "#### On pizza payment received")
    end

    it "groups a thing's terms under what can be done, what it records, its lists and its parts" do
      groups = markdown.scan(/^### (.+)$/).flatten
      expect(groups).to eq(["Actions", "What it records", "Lists", "What it is made of"])
    end

    it "says what an action needs, checks, changes and records" do
      expect(markdown).to include(PIZZAS_PURCHASE_TERM)
    end

    it "describes each list from its filter, its order and what it asks for", :aggregate_failures do
      expect(markdown).to include("Orders that are available, sorted by pizza name, A to Z.",
                                  "Orders whose price is less than the ceiling you give, sorted by pizza name, A to Z.",
                                  "All orders, sorted by customer name, A to Z, with orders that have no customer name last.",
                                  "All orders, sorted by price, highest first.")
    end

    it "says a value's pattern in words" do
      expect(markdown).to include("#### Customer name\n\nText that must not be blank.")
    end

    it "writes its own fixed copy without dashes standing in for punctuation" do
      fixed = [Hecks::Projections::Glossary::Markdown::LEDE, *Hecks::Projections::Glossary::Markdown::STANDING.values]
      expect(fixed.grep(/—/)).to be_empty
    end

    it "draws no map and no picture of how a lone thing fits", :aggregate_failures do
      expect(markdown).not_to include("**How it fits**")
      expect(markdown.scan("```mermaid").size).to eq(1)
    end
  end
end
