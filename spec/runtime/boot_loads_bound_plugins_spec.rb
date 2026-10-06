require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# A domain bound to PostgresEra boots with the era plugin loaded, without the
# application requiring the plugin file itself. Each example boots in a fresh
# Ruby process since the plugin registers itself process-wide.
RSpec.describe "Booting a domain bound to a lazily loaded persistence plugin" do
  let(:scratch) { Dir.mktmpdir("hecks-bound-plugin-spec") }
  let(:lib) { File.expand_path("../../lib", __dir__) }

  after { FileUtils.remove_entry(scratch) }

  BOUND_PLUGIN_TARGET_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Target" do
      vision "a domain bound to a persistence adapter"
      core

      aggregate "Widget" do
        description "a widget"
        identified_by :ref

        value_object "Ref" do
          attribute :value, String
          invariant("a widget has a ref") { !value.to_s.empty? }
        end

        attribute :ref, Ref

        command "Make" do
          goal "make a widget"
          attribute :ref, Ref
          emits "WidgetMade"
        end

        query "All" do
        end
      end
    end
  BLUEBOOK

  def write_domain_file(extension, content)
    File.write(File.join(scratch, "bluebook", "target.#{extension}"), content)
  end

  def write_domain(adapter:, database: nil)
    FileUtils.mkdir_p(File.join(scratch, "bluebook"))
    write_domain_file("bluebook", BOUND_PLUGIN_TARGET_BLUEBOOK)
    write_domain_file("hecksagon", <<~HECKSAGON)
      Hecks.hecksagon "Target" do
        persisted_by "#{adapter}"
      end
    HECKSAGON
    write_domain_file("world", world_for(adapter, database)) if database
  end

  def world_for(adapter, database)
    <<~WORLD
      Hecks.world "Target" do
        persisted_by("#{adapter}") do
          database "#{database}"
        end
      end
    WORLD
  end

  # Runs a script in a fresh Ruby process and parses the one JSON line it prints.
  def run_fresh(script)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", "require 'hecks'\nrequire 'json'\n#{script}")
    raise "fresh process failed:\n#{err}" unless status.success?

    JSON.parse(out.lines.last)
  end

  # Loads the domain the way a boot does, up to but not including the gates.
  def loaded_registry_script
    <<~RUBY
      loading = Hecks::Ports::Loading.bootstrap
      directory = loading.bluebook_directory(#{scratch.inspect})
      registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
      Hecks.with_registry(registry) do
        loading.load_library
        loading.load_project(loading.shared_root(nil, directory))
        loading.load_domain(directory, environment: nil)
      end
    RUBY
  end

  ERA_PLUGIN_PROBE = <<~RUBY.freeze
    before = Hecks::Ports::Persistence.plugin?(:era)
    Hecks::Runtime::Loader.load_bound_adapters!(registry)
    puts JSON.generate(before: before, after: Hecks::Ports::Persistence.plugin?(:era))
  RUBY

  MEMORY_ONLY_PROBE = <<~RUBY.freeze
    Hecks::Runtime::Loader.load_bound_adapters!(registry)
    puts JSON.generate(after: Hecks::Ports::Persistence.plugins_loaded?)
  RUBY

  UNIMPLEMENTED_ADAPTER_PROBE = <<~RUBY.freeze
    Hecks::Runtime::Loader.load_bound_adapters!(registry)
    puts JSON.generate(loaded: true)
  RUBY

  # Runs a probe in a fresh Ruby process after the domain is loaded the way a boot does.
  def run_after_load(probe) = run_fresh("#{loaded_registry_script}\n#{probe}")

  it "loads the era plugin when a hecksagon binds PostgresEra" do
    write_domain(adapter: "PostgresEra", database: "postgres:///never_connected")

    expect(run_after_load(ERA_PLUGIN_PROBE)).to eq("before" => false, "after" => true)
  end

  it "loads nothing when the domain binds only Memory" do
    write_domain(adapter: "Memory")

    expect(run_after_load(MEMORY_ONLY_PROBE)).to eq("after" => false)
  end

  it "leaves an adapter with no Ruby implementation for verify! to refuse" do
    write_domain(adapter: "Nonesuch")

    expect(run_after_load(UNIMPLEMENTED_ADAPTER_PROBE)).to eq("loaded" => true)
  end

  describe "a full boot", :io do
    let(:database) { "hecks_bound_plugin_spec_#{SecureRandom.hex(3)}" }

    before do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      admin.exec("CREATE DATABASE #{database}")
      admin.close
      FencedOwner.own!(database)
    end

    after do
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{database} WITH (FORCE)")
      admin.close
    end

    GATE_RECORDER = <<~RUBY.freeze
      registered = []
      Hecks::Runtime::BootGates.prepend(Module.new do
        define_method(:register) do |name, gate, phase:|
          registered << name
          super(name, gate, phase: phase)
        end
      end)
    RUBY

    def full_boot_script
      <<~RUBY
        #{GATE_RECORDER}
        Hecks.boot(#{scratch.inspect})
        puts JSON.generate(plugin: Hecks::Ports::Persistence.plugin?(:era), gates: registered)
      RUBY
    end

    it "registers the era gates and boots without the application requiring the plugin", :aggregate_failures do
      write_domain(adapter: "PostgresEra", database: FencedOwner.url(database))

      seen = run_fresh(full_boot_script)

      expect(seen).to include("plugin" => true)
      expect(seen["gates"]).to include("era_compute_rules", "era_check")
    end
  end
end
