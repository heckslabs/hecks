require "spec_helper"
require "hecks/framework_bluebooks"

# `FrameworkBluebooks.load!` brings a gem bluebook into the open registry whole or not at all.
RSpec.describe Hecks::FrameworkBluebooks, ".load!" do
  around do |example|
    Hecks.with_registry(Hecks::Runtime::Registry.new) do
      MemoryPorts.load!
      example.run
    end
  end

  let(:registry) { Hecks.current_registry }
  let(:paths)    { described_class.index.fetch("Deploy") }

  # Loads every file of the bluebook, then raises after the last one.
  def fail_after_last_file
    allow(Kernel).to receive(:load).and_wrap_original do |original, path, *rest|
      original.call(path, *rest)
      raise "boom after #{File.basename(path)}" if path == paths.last
    end
  end

  it "leaves no half-loaded bluebook behind when a file raises", :aggregate_failures do
    fail_after_last_file

    expect { described_class.load!("Deploy") }.to raise_error(/boom after/)
    expect(registry.bluebook("Deploy")).to be_nil
    expect(registry.bluebook_sources).not_to have_key("Deploy")
    expect(Hecks::Bluebook::MetaValidator.deferred_bluebooks).not_to include("Deploy")
  end

  it "loads the bluebook on a retry after a file raised", :aggregate_failures do
    fail_after_last_file
    expect { described_class.load!("Deploy") }.to raise_error(/boom after/)
    RSpec::Mocks.space.proxy_for(Kernel).reset

    expect(described_class.load!("Deploy")).to be true
    expect(registry.bluebook("Deploy")).not_to be_nil
  end

  it "returns nil for a bluebook it already loaded" do
    described_class.load!("Deploy")

    expect(described_class.load!("Deploy")).to be_nil
  end

  it "raises a WiringError, not a NoMethodError, outside a boot" do
    allow(Hecks).to receive(:current_registry).and_return(nil)

    expect { described_class.load!("Deploy") }
      .to raise_error(Hecks::Runtime::WiringError, /no registry is open/)
  end

  def open_session_command
    proc do
      command("Open") do
        attribute :id, Id
        sets :id
        emits "Opened"
      end
    end
  end

  def declare_user_deploy_bluebook
    open_session = open_session_command
    Hecks.bluebook("Deploy") do
      aggregate("Session") do
        identified_by :id
        attribute :id, Id
        value_object "Id", String
        instance_eval(&open_session)
      end
    end
  end

  it "refuses a user bluebook that shares the attachable bluebook's name" do
    declare_user_deploy_bluebook

    expect { described_class.load!("Deploy") }
      .to raise_error(Hecks::Runtime::WiringError, /already declared in .*bluebooks_load_spec/)
  end
end
