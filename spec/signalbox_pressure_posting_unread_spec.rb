# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/signalbox/adapters/pressure_posting"

# A signal is not posted on marks the world did not set.
RSpec.describe Hecks::Adapters::PressurePosting, "#post" do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "pressure.json") }
  let(:broken) { Struct.new(:found) { def for_verb(_name) = raise("unreadable") }.new }
  let(:registry) { Struct.new(:found) { def world(_name) = found }.new(broken) }

  after { FileUtils.remove_entry(dir) }

  let(:posting) { described_class.new(registry: registry, settings: { path: path }) }

  it "raises Unread" do
    expect { posting.post(pressure: "p", band: "normal") }.to raise_error(Hecks::Adapters::Looking::Marks::Unread)
  end

  it "posts nothing" do
    begin
      posting.post(pressure: "p")
    rescue Hecks::Adapters::Looking::Marks::Unread
      nil
    end
    expect(File.exist?(path)).to be(false)
  end
end
