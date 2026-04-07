require "spec_helper"

RSpec.describe "Self-hosting: Hecks generates itself", :slow do
  include HecksTemplating::NamingHelpers

  before(:all) do
    Dir.glob(File.join(File.dirname(__FILE__), "..", "..", "**/lib/hecks/chapters/*.rb"))
      .reject { |f| f.include?("/.claude/") }
      .each { |f| require f }
  end

  let(:chapters) do
    Hecks::Chapters.constants
      .map { |c| Hecks::Chapters.const_get(c) }
      .select { |m| m.respond_to?(:definition) }
  end

  it "discovers all 15 chapters" do
    expect(chapters.size).to eq(15)
  end

  it "boots every chapter as a running Hecks app" do
    chapters.each do |ch|
      domain = ch.definition
      mod_name = domain_module_name(domain.name)

      Hecks::InMemoryLoader.load(domain, mod_name) unless Object.const_defined?(mod_name)
      app = Hecks::Runtime.new(domain)

      expect(app).to be_a(Hecks::Runtime),
        "#{domain.name} failed to boot"
      expect(app.domain.aggregates.size).to be > 0,
        "#{domain.name} has no aggregates"
    end
  end

  it "fires all 836 commands across all chapters" do
    executed = 0

    chapters.each do |ch|
      domain = ch.definition
      mod_name = domain_module_name(domain.name)

      Hecks::InMemoryLoader.load(domain, mod_name) unless Object.const_defined?(mod_name)
      app = Hecks::Runtime.new(domain)

      domain.aggregates.each do |agg|
        agg.commands.each do |cmd|
          app.run(cmd.name)
          executed += 1
        end
      end
    end

    expect(executed).to eq(836)
  end
end
