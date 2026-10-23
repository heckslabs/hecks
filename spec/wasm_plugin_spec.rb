require "spec_helper"
require "tmpdir"
require "fileutils"

# A query a wasm plugin answers: the bluebook declares the question and the value object its answer
# takes, and a plugin adapter beside it says it answers that query and names the module that does.
# No hecksagon line binds it. The module is a WASI command (JSON in on stdin, JSON out on stdout),
# the same one both hosts run, and a referenced record reaches it as that record's stored state.
RSpec.describe "a query a wasm plugin answers" do
  DOUBLER_WASM = File.expand_path("fixtures/wasm_plugin/doubler.wasm", __dir__)

  PLUGINNED_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Pluginned" do
      vision "A plugin doubles what it is asked."

      aggregate "Ledger" do
        description "A ledger with a note."

        attribute :name, LedgerName
        attribute :note, Note
        identified_by :name

        value_object "LedgerName" do
          attribute :value, String
        end

        value_object "Note" do
          attribute :value, String
        end

        value_object "Doubling" do
          attribute :amount, Integer
          attribute :note,   String
        end

        query "Doubled" do
          reference_to Ledger, as: :entry
          attribute :amount, Integer
          returns list_of(Doubling)
        end

        query "Tripled" do
          attribute :amount, Integer
          returns list_of(Doubling)
        end

        command "Open" do
          attribute :name, LedgerName
          attribute :note, Note
          sets :name
          sets :note
          emits Opened
        end
      end
    end
  RUBY

  PLUGINNED_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Pluginned" do
      persisted_by "Memory"
    end
  RUBY

  def plugin_adapter(name, answers: ["Pluginned::Ledger.Doubled", "Pluginned::Ledger.Tripled"], runs: "doubler.wasm")
    lines = answers.map { |query| %(  answers_query "#{query}") } + (runs ? [%(  runs "#{runs}")] : [])
    "Hecks.adapter \"#{name}\" do\n#{lines.join("\n")}\nend\n"
  end

  def write_domain(adapters: { "doubler" => plugin_adapter("Doubler") }, wasm: true)
    dir = File.join(@dir, "bluebook")
    FileUtils.mkdir_p(File.join(dir, "adapters"))
    File.write(File.join(dir, "pluginned.bluebook"), PLUGINNED_BLUEBOOK)
    File.write(File.join(dir, "pluginned.hecksagon"), PLUGINNED_HECKSAGON)
    adapters.each { |file, text| File.write(File.join(dir, "adapters", "#{file}.adapter"), text) }
    FileUtils.cp(DOUBLER_WASM, File.join(dir, "adapters", "doubler.wasm")) if wasm
  end

  def boot_domain(**options)
    write_domain(**options)
    Hecks.boot(@dir, install_driving: false)
  end

  around do |example|
    Dir.mktmpdir("wasm_plugin") do |dir|
      @dir = dir
      example.run
    end
  end

  describe "an answer" do
    it "comes from the module, with the referenced record handed over as its stored state" do
      runtime = boot_domain
      runtime.dispatch("Pluginned::Ledger.Open", with: { name: { value: "house" }, note: { value: "rent" } })

      expect(runtime.query("Pluginned::Ledger.Doubled", entry: "house", amount: 21))
        .to eq([{ amount: 42, note: "rent" }])
    end

    it "carries the module's refusal, in its own words" do
      runtime = boot_domain

      expect { runtime.query("Pluginned::Ledger.Tripled", amount: 1) }
        .to raise_error(Hecks::Runtime::PluginRefusal, /doubler does not answer Pluginned::Ledger.Tripled/)
    end

    it "refuses a reference to a record that is not there, before the module is asked" do
      runtime = boot_domain

      expect { runtime.query("Pluginned::Ledger.Doubled", entry: "nowhere", amount: 1) }
        .to raise_error(Hecks::Runtime::NotFound, /no Ledger "nowhere"/)
    end
  end

  describe "the IR a host reads" do
    it "carries the module and, for each question, the aggregate each reference names", :aggregate_failures do
      runtime = boot_domain
      plugins = Hecks::Projector::Exporter.plugins(runtime.registry)
      expect(plugins.size).to eq(1)
      plugin = plugins.first

      expect(plugin.slice("adapter", "runs")).to eq("adapter" => "Doubler", "runs" => "doubler.wasm")
      expect(plugin["queries"]).to eq(
        [{ "question" => "Pluginned::Ledger.Doubled", "references" => { "entry" => "Pluginned::Ledger" } },
         { "question" => "Pluginned::Ledger.Tripled", "references" => {} }]
      )
      expect(Base64.strict_decode64(plugin["module"])).to eq(File.binread(DOUBLER_WASM))
      expect(plugin["sha256"]).to eq(Digest::SHA256.file(DOUBLER_WASM).hexdigest)
    end
  end

  describe "the boot" do
    it "refuses a query two plugins say they answer" do
      adapters = { "doubler" => plugin_adapter("Doubler"), "rival" => plugin_adapter("Rival") }

      expect { boot_domain(adapters: adapters) }
        .to raise_error(Hecks::Runtime::WiringError, /2 plugins answer Pluginned::Ledger.Doubled \(Doubler, Rival\)/)
    end

    it "refuses a plugin whose module is not beside it" do
      expect { boot_domain(wasm: false) }
        .to raise_error(Hecks::Runtime::WiringError, /Doubler runs doubler.wasm, but there is no .*doubler.wasm/)
    end

    it "still refuses a returns query nothing answers" do
      adapters = { "doubler" => plugin_adapter("Doubler", answers: ["Pluginned::Ledger.Doubled"]) }

      expect { boot_domain(adapters: adapters) }
        .to raise_error(Hecks::Runtime::WiringError, /Ledger.Tripled has no answer path/)
    end
  end

  describe "the adapter language" do
    it "refuses a query answered by an adapter that runs nothing" do
      expect { boot_domain(adapters: { "doubler" => plugin_adapter("Doubler", runs: nil) }) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /only a plugin answers queries/)
    end

    it "refuses a module path that leaves the adapter's directory, and a query written short" do
      expect { boot_domain(adapters: { "doubler" => plugin_adapter("Doubler", runs: "../doubler.wasm") }) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /PluginModule/)
      expect { boot_domain(adapters: { "doubler" => plugin_adapter("Doubler", answers: ["Ledger.Doubled"]) }) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /AnsweredQuery/)
    end
  end
end
