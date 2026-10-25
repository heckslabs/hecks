require "spec_helper"
require "tmpdir"
require "hecks/rust_build/command_schemas"
require_relative "support/booted_source"

# The host has no Ruby, so the build writes each command's schema beside the IR for it to serve.
RSpec.describe Hecks::RustBuild::CommandSchemas do
  SHOP_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Shopping" do
      aggregate "Item" do
        identified_by :tag
        attribute :tag, Tag
        value_object("Tag") { attribute :value, String }
        command("Add") do
          goal "Add an item"
          attribute :tag, Tag
          sets :tag
          emits "ItemAdded"
        end
      end
    end
  BLUEBOOK

  let(:bluebook) do
    BootedSource.boot(SHOP_SOURCE) { Hecks.hecksagon("Shopping") { Shopping::Item.persisted_by("Memory") } }
                .registry.bluebook("Shopping")
  end

  def written_schemas
    Dir.mktmpdir do |dir|
      JSON.parse(File.read(described_class.write(bluebook, dir)))
    end
  end

  it "writes a schema per command, keyed Aggregate/Command" do
    expect(written_schemas.keys).to eq(["Item/Add"])
  end

  it "writes each as a draft 2020-12 document" do
    expect(written_schemas["Item/Add"]["$schema"]).to eq("https://json-schema.org/draft/2020-12/schema")
  end
end
