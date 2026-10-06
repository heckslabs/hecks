require "spec_helper"

# `default_database`/`default_adapter` — a world's project-wide fallback for
# per-chapter binds; a chapter's own declaration still wins over the default.
RSpec.describe "a world's project-wide defaults" do
  def url = "postgres://localhost/defaults_spec"

  def chapters = { "Alpha" => %w[Order Invoice], "Beta" => %w[Ticket], "Gamma" => %w[Note] }

  # The body of an aggregate named `name`: a label identity and an Open command.
  def opening_aggregate(name)
    proc do
      identified_by :label
      attribute :label, Label
      value_object("Label") { attribute :value, String }
      command "Open" do
        attribute :label, Label
        emits "#{name}Opened"
      end
    end
  end

  def declare_chapters
    chapters.each do |chapter, aggregates|
      bodies = aggregates.map { |name| [name, opening_aggregate(name)] }
      Hecks.bluebook(chapter) do
        supporting
        bodies.each { |name, body| aggregate(name, &body) }
      end
    end
  end

  def build(&declarations)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks::Adapters::Folder.new.load_library
      declare_chapters
      declarations.call
    end
    registry
  end

  def aggregates_of(registry)
    registry.bluebooks.flat_map { |name, chapter| chapter.aggregates.map { |aggregate| [name, aggregate] } }
  end

  def resolved(registry)
    aggregates_of(registry).map do |domain, aggregate|
      bind = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate)
      [domain, aggregate.hecks_name, bind.verb, bind.adapter, registry.binding_settings(domain, bind.verb, bind.adapter)]
    end
  end

  def expanded
    connection = url
    build do
      %w[Alpha Beta Gamma].each do |chapter|
        Hecks.hecksagon(chapter) { persisted_by "PostgresEra" }
        Hecks.world(chapter) do
          realm "Spec"
          persisted_by("PostgresEra") { database connection }
        end
      end
    end
  end

  def defaulted(&overrides)
    connection = url
    build do
      Hecks.world("Alpha") do
        realm "Spec"
        default_adapter "PostgresEra"
        default_database connection
      end
      overrides&.call
    end
  end

  it "resolves every chapter's aggregates exactly as the per-chapter form does" do
    expect(resolved(defaulted)).to eq(resolved(expanded))
  end

  it "reaches chapters that declare no world and no hecksagon at all" do
    expect(resolved(defaulted).map { |row| row[3] }.uniq).to eq(["PostgresEra"])
  end

  it "hands a database-taking adapter the default database" do
    expect(defaulted.binding_settings("Gamma", "persisted_by", "PostgresEra"))
      .to eq(adapter: "PostgresEra", database: url)
  end

  it "keeps the framework's in-memory fallback for a world that declares no default" do
    registry = build { Hecks.world("Alpha") { realm "Spec" } }

    expect(resolved(registry).map { |row| row[3] }.uniq).to eq(["Memory"])
  end

  it "leaves settings exactly as declared when no default database is named" do
    registry = build { Hecks.world("Alpha") { persisted_by("PostgresEra") { database "elsewhere" } } }

    expect(registry.binding_settings("Alpha", "persisted_by", "PostgresEra"))
      .to eq(registry.world("Alpha").for_binding("persisted_by", "PostgresEra"))
  end

  describe "the chapter's own declarations win" do
    it "over the default adapter, aggregate by aggregate" do
      registry = defaulted { Hecks.hecksagon("Alpha") { Alpha::Order.persisted_by("Memory") } }
      adapters = resolved(registry).to_h { |row| ["#{row[0]}::#{row[1]}", row[3]] }

      expect(adapters).to include("Alpha::Order" => "Memory", "Alpha::Invoice" => "PostgresEra")
    end

    it "over the default adapter, through its own domain-level bind" do
      registry = defaulted { Hecks.hecksagon("Beta") { persisted_by "Memory" } }

      expect(resolved(registry).select { |row| row[0] == "Beta" }.map { |row| row[3] }).to eq(["Memory"])
    end

    it "over the project's default, through the chapter's own world default" do
      registry = defaulted { Hecks.world("Gamma") { default_adapter "Memory" } }

      expect(resolved(registry).select { |row| row[0] == "Gamma" }.map { |row| row[3] }).to eq(["Memory"])
    end

    it "over the default database, when its own settings name one" do
      registry = defaulted { Hecks.world("Beta") { persisted_by("PostgresEra") { database "postgres://elsewhere/beta" } } }

      expect(registry.binding_settings("Beta", "persisted_by", "PostgresEra"))
        .to eq(adapter: "PostgresEra", database: "postgres://elsewhere/beta")
    end

    it "field by field, so a setting it leaves out still takes the default" do
      registry = defaulted { Hecks.world("Beta") { persisted_by("PostgresEra") { schema "beta" } } }

      expect(registry.binding_settings("Beta", "persisted_by", "PostgresEra"))
        .to eq(adapter: "PostgresEra", schema: "beta", database: url)
    end
  end

  describe "the default database" do
    it "never reaches an adapter that declares no database" do
      expect(defaulted.binding_settings("Alpha", "persisted_by", "Memory")).to eq({})
    end

    it "never reaches a bind under another verb" do
      expect(defaulted.binding_settings("Alpha", "projected_by", "SqliteProjection")).to eq({})
    end
  end

  describe "an environment overlay" do
    it "replaces the default adapter and keeps the default database" do
      registry = defaulted { Hecks.world("Alpha") { default_adapter "Memory" } }

      expect(registry.world("Alpha")).to have_attributes(default_adapter: "Memory", default_database: url)
    end
  end

  describe "boot verification" do
    it "accepts a default adapter that is a persistence adapter" do
      registry = build { Hecks.world("Alpha") { default_adapter "Memory" } }

      expect(registry.verify_world_defaults!).to equal(registry)
    end

    it "refuses a default adapter no adapter answers to" do
      registry = build { Hecks.world("Alpha") { default_adapter "NoSuchAdapter" } }

      expect { registry.verify_world_defaults! }
        .to raise_error(Hecks::Runtime::WiringError, /Alpha's world declares default_adapter "NoSuchAdapter"/)
    end

    it "refuses a default adapter that answers a different port" do
      registry = build { Hecks.world("Alpha") { default_adapter "SqliteProjection" } }

      expect { registry.verify_world_defaults! }
        .to raise_error(Hecks::Runtime::WiringError, /cannot satisfy persisted_by/)
    end
  end

  describe "saga rehydration" do
    it "walks a chapter the default adapter binds though it has no hecksagon" do
      expect(defaulted.saga_domains).to contain_exactly("Alpha", "Beta", "Gamma")
    end

    it "walks only hecksagon domains when no default adapter is declared" do
      registry = build { Hecks.hecksagon("Alpha") { persisted_by "Memory" } }

      expect(registry.saga_domains).to eq(["Alpha"])
    end
  end
end
