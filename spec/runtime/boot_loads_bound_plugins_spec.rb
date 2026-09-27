require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# A domain that declares `persisted_by "PostgresEra"` boots with the era plugin
# loaded and its gates registered, without the application requiring
# "hecks/ports/persistence/plugins/era" first.
#
# The plugin registers itself process-wide when it loads, and other specs load
# it, so each example runs the boot in a fresh Ruby process and reads the answer
# back from its output.
RSpec.describe "Booting a domain bound to a lazily loaded persistence plugin" do
  let(:scratch) { Dir.mktmpdir("hecks-bound-plugin-spec") }
  let(:lib) { File.expand_path("../../lib", __dir__) }

  after { FileUtils.remove_entry(scratch) }

  def write_domain(adapter:, database: nil)
    FileUtils.mkdir_p(File.join(scratch, "bluebook"))
    File.write(File.join(scratch, "bluebook", "target.bluebook"), <<~BLUEBOOK)
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
    File.write(File.join(scratch, "bluebook", "target.hecksagon"), <<~HECKSAGON)
      Hecks.hecksagon "Target" do
        persisted_by "#{adapter}"
      end
    HECKSAGON
    return unless database

    File.write(File.join(scratch, "bluebook", "target.world"), <<~WORLD)
      Hecks.world "Target" do
        persisted_by("#{adapter}") do
          database "#{database}"
        end
      end
    WORLD
  end

  # Runs a script in a fresh Ruby that has required hecks and nothing else, and
  # parses the one JSON line it prints.
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

  it "loads the era plugin when a hecksagon binds PostgresEra" do
    write_domain(adapter: "PostgresEra", database: "postgres:///never_connected")

    seen = run_fresh(<<~RUBY)
      #{loaded_registry_script}
      before = Hecks::Ports::Persistence.plugin?(:era)
      Hecks::Runtime::Loader.load_bound_adapters!(registry)
      puts JSON.generate(before: before, after: Hecks::Ports::Persistence.plugin?(:era))
    RUBY

    expect(seen).to eq("before" => false, "after" => true)
  end

  it "loads nothing when the domain binds only Memory" do
    write_domain(adapter: "Memory")

    seen = run_fresh(<<~RUBY)
      #{loaded_registry_script}
      Hecks::Runtime::Loader.load_bound_adapters!(registry)
      puts JSON.generate(after: Hecks::Ports::Persistence.plugins_loaded?)
    RUBY

    expect(seen).to eq("after" => false)
  end

  it "leaves an adapter with no Ruby implementation for verify! to refuse" do
    write_domain(adapter: "Nonesuch")

    seen = run_fresh(<<~RUBY)
      #{loaded_registry_script}
      Hecks::Runtime::Loader.load_bound_adapters!(registry)
      puts JSON.generate(loaded: true)
    RUBY

    expect(seen).to eq("loaded" => true)
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

    it "registers the era gates and boots without the application requiring the plugin" do
      write_domain(adapter: "PostgresEra", database: FencedOwner.url(database))

      seen = run_fresh(<<~RUBY)
        registered = []
        Hecks::Runtime::BootGates.prepend(Module.new do
          define_method(:register) do |name, gate, phase:|
            registered << name
            super(name, gate, phase: phase)
          end
        end)
        Hecks.boot(#{scratch.inspect})
        puts JSON.generate(plugin: Hecks::Ports::Persistence.plugin?(:era), gates: registered)
      RUBY

      expect(seen).to include("plugin" => true)
      expect(seen["gates"]).to include("era_compute_rules", "era_check")
    end
  end
end
