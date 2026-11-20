require "spec_helper"
require "tmpdir"
require "fileutils"

# A deploy names a component adapter in its hecksagon (`mailed_by "Resend"`), and the IR the
# Rust host reads carries that component: its module and digest, the port it answers and the
# grant the host cuts for it. A hecksagon that names none carries no `components`.
module MailedDomain
  BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Mailed" do
      vision "A note is mailed."

      aggregate "Note" do
        description "A note."
        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String
        end

        command "Write" do
          attribute :title, Title
          sets :title
          emits Written
        end
      end
    end
  RUBY

  COMMITTED = File.expand_path("../lib/hecks/adapters/driven/resend", __dir__)

  def boot_mailed(wiring)
    dir = File.join(@dir, "bluebook")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "mailed.bluebook"), BLUEBOOK)
    File.write(File.join(dir, "mailed.hecksagon"), %(Hecks.hecksagon "Mailed" do\n#{wiring}\nend\n))
    Hecks.boot(@dir, install_driving: false).registry
  end

  def components(wiring = %(  persisted_by "Memory"\n  mailed_by "Resend"))
    Hecks::Projector::Exporter.components(boot_mailed(wiring), "Mailed")
  end

  def committed_digest = File.readlines(File.join(COMMITTED, "resend.wasm.sha256")).last.split.first
end

RSpec.describe "a component adapter a hecksagon wires" do
  include MailedDomain

  around do |example|
    Dir.mktmpdir("wasm_component") do |dir|
      @dir = dir
      example.run
    end
  end

  describe "the IR's components" do
    it "names the component, the port it answers and its grant" do
      expect(components.map { |entry| entry.except("module", "sha256") })
        .to eq([{ "adapter" => "Resend", "port" => "email", "verb" => "mailed_by", "runs" => "resend.wasm",
                  "secrets" => ["RESEND_API_KEY"], "imports" => %w[clock http_out], "hosts" => ["api.resend.com"] }])
    end

    it "carries the committed module, by the digest committed beside it", :aggregate_failures do
      entry = components.first
      expect(entry["sha256"]).to eq(committed_digest)
      expect(Base64.strict_decode64(entry["module"])).to eq(File.binread(File.join(MailedDomain::COMMITTED, "resend.wasm")))
    end

    it "is empty for a hecksagon that names no component" do
      expect(components(%(  persisted_by "Memory"))).to eq([])
    end

    it "keeps a component out of the plugins, which answer queries" do
      registry = boot_mailed(%(  persisted_by "Memory"\n  mailed_by "Resend"))
      expect(Hecks::Projector::Exporter.plugins(registry).map { |plugin| plugin["adapter"] }).not_to include("Resend")
    end
  end

  describe "the adapter language" do
    def judge(text) = Hecks::Bluebook::DSL::AdapterBuilder.build("Stray") { instance_eval(text) }

    it "refuses imports on an adapter that runs no component" do
      expect { judge(%(port "email"\nimports :clock)) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /only a component imports/)
    end

    it "refuses a host on an adapter that runs no component" do
      expect { judge(%(imports hosts: ["api.resend.com"])) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /only a component reaches a host/)
    end

    it "refuses an import the host does not grant" do
      expect { judge(%(port "email"\nruns "x.wasm"\nimports :network)) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /AdapterImport/)
    end
  end
end
