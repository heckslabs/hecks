require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/extensions/serve"
require "hecks_ai"

RSpec.describe "Extension adapter_type classification" do
  describe "driven_extensions" do
    it "returns extensions declared as driven" do
      driven = Hecks.driven_extensions
      expect(driven).to include(:auth, :validations, :logging, :idempotency,
                                :retry, :rate_limit, :pii, :tenancy, :audit,
                                :filesystem_store)
    end

    it "does not include driving extensions" do
      driven = Hecks.driven_extensions
      expect(driven).not_to include(:http, :mcp)
    end
  end

  describe "driving_extensions" do
    it "returns extensions declared as driving" do
      driving = Hecks.driving_extensions
      expect(driving).to include(:http, :mcp)
    end

    it "does not include driven extensions" do
      driving = Hecks.driving_extensions
      expect(driving).not_to include(:auth, :validations, :logging)
    end
  end

  describe "extension_meta stores adapter_type" do
    it "records driven type in metadata" do
      meta = Hecks.extension_meta[:auth]
      expect(meta[:adapter_type]).to eq(:driven)
    end

    it "records driving type in metadata" do
      meta = Hecks.extension_meta[:http]
      expect(meta[:adapter_type]).to eq(:driving)
    end

    it "defaults to nil for untyped extensions" do
      Hecks.describe_extension(:test_untyped, description: "test")
      expect(Hecks.extension_meta[:test_untyped][:adapter_type]).to be_nil
    ensure
      Hecks.extension_meta.delete(:test_untyped)
    end
  end

  describe "two-phase boot ordering" do
    let(:tmpdir) { Dir.mktmpdir("hecks-adapter-type-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "fires driven extensions before driving extensions" do
      order = []
      Hecks.register_extension(:test_driven) { |*, **| order << :driven }
      Hecks.describe_extension(:test_driven,
        description: "test", adapter_type: :driven)
      Hecks.register_extension(:test_driving) { |*, **| order << :driving }
      Hecks.describe_extension(:test_driving,
        description: "test", adapter_type: :driving)

      File.write(File.join(tmpdir, "OrderBluebook"), <<~RUBY)
        Hecks.domain "AdapterOrderTest" do
          aggregate "Widget" do
            attribute :name, String
            command "CreateWidget" do
              attribute :name, String
            end
          end
        end
      RUBY

      Hecks.boot(tmpdir)
      driven_idx = order.index(:driven)
      driving_idx = order.index(:driving)
      expect(driven_idx).not_to be_nil
      expect(driving_idx).not_to be_nil
      expect(driven_idx).to be < driving_idx
    ensure
      Hecks.extension_registry.delete(:test_driven)
      Hecks.extension_registry.delete(:test_driving)
      Hecks.extension_meta.delete(:test_driven)
      Hecks.extension_meta.delete(:test_driving)
    end
  end
end
