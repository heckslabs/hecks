# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# Drawing the board's pages to images: one image per page for the live state and for the staged bad
# day, the staged day built from nothing on the machine, and a refusal by name.
RSpec.describe Hecks::Adapters::PipelineBoard::Pictures do
  let(:dir) { Dir.mktmpdir("board-pictures") }
  let(:drawn) { [] }
  let(:browser) { Object.new.tap { |fake| fake.define_singleton_method(:shoot) { |url, path| File.write(path, url) && path } } }
  let(:board) { Hecks::Adapters::PipelineWeb.new(settings: { browser: browser }, root: dir) }

  after { FileUtils.rm_rf(dir) }

  def draw(state) = board.draw_pages(state: { value: state }, into: { value: dir })

  it "draws one image per page of the staged bad day" do
    draw("bad_day")
    expect(Dir.children(dir).sort).to eq(described_class::PAGES.values.map { |name| "bad_day-#{name}.png" }.sort)
  end

  it "asks each page of the board over its own address", :aggregate_failures do
    draw("bad_day")
    urls = Dir[File.join(dir, "*.png")].map { |file| File.read(file) }
    expect(urls.size).to eq(9)
    expect(urls).to all(match(%r{\Ahttp://127\.0\.0\.1:\d+/}))
  end

  it "refuses a state the board does not draw" do
    expect { draw("tuesday") }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /no such state/)
  end

  it "stages the bad day without reading the machine", :aggregate_failures do
    state = Hecks::Adapters::PipelineBoard::BadDay.new.state
    expect(state[:waiting_on_you][:count]).to eq(3)
    expect(state[:stages].map { |row| row[:state] }).to include("failed")
  end

  it "stages one day, whenever it is drawn" do
    days = Array.new(2) { Hecks::Adapters::PipelineBoard::BadDay.new.state }
    expect(days.first).to eq(days.last)
  end

  it "has no browser to draw with when none is found" do
    allow(File).to receive(:executable?).and_return(false)
    stub_const("ENV", ENV.to_h.except("BOARD_BROWSER"))
    none = Hecks::Adapters::PipelineBoard::Browser.new
    expect { none.shoot("http://127.0.0.1/", File.join(dir, "x.png")) }.to raise_error(/no browser to draw with/)
  end
end
