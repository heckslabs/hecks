# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page never grows with its text: every element the writer fills with a long run of
# text sits under a rule that bounds it (a height with its own scroll, or a line clamp, or one
# ellipsized line). A page drawn with oversized text everywhere must hold no element without one.
RSpec.describe "the planning page's bounded text" do
  # The elements the page is known to fill with long text, as the selectors that must bound them.
  let(:places) { [".review pre", ".detail pre", ".outcome", ".what", ".facts", ".area", ".next", ".name b"] }
  let(:long) { 250 }
  let(:css) { File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/plan.html", __dir__) }

  let(:page) do
    epic = { epic: "big", title: words(300), outcome: words(3500), tier: "", done: 1, dropped: 0,
             closed: [{ slug: "old", title: words(300), status: "done" }] }
    reading = Hecks::Adapters::PipelineBoard::PlanReading.build(
      items: [row("a"), row("b")], epics: [epic], sessions: [],
      reviews: [{ work: "a", run: "r1", verdict: "changes", findings: "**Verdict:** #{words(6000)}" }],
      fill: { would_start: [], skipped: [] },
      train: { name: "Train", state: "ok", count: "0", detail: "idle" }, now: Time.utc(2026, 11, 11, 12)
    )
    Hecks::Adapters::PipelineBoard::PlanHtml.draw(reading)
  end

  def words(size) = ("word " * ((size / 5) + 1))[0, size]

  def row(slug, **fields)
    { slug: slug, title: words(300), status: "planned", area: [words(300)], priority: "", category: "",
      epic: "big", claimed_by: "", claimed_at: "", budget_minutes: 90, yield_count: 3,
      reason: words(600), step: 1, detail: words(3000) }.merge(fields)
  end

  # @return [Array<String>] the selector each element holding a long run of text answers to: its own
  #   class, or its tag under the nearest classed ancestor
  def long_places(html)
    stack = []
    found = []
    html.scan(%r{<(/?)([a-z0-9]+)([^>]*)>|([^<]+)}) do |close, tag, attrs, text|
      if text
        found << place(stack) if long_text?(stack, text)
      else
        track(stack, close, tag, attrs)
      end
    end
    found.uniq
  end

  def long_text?(stack, text) = stack.any? && CGI.unescapeHTML(text).strip.length > long

  def track(stack, close, tag, attrs)
    return if %w[br i input meta link hr].include?(tag)

    close.empty? ? stack << [tag, attrs[/class="([^" ]+)/, 1]] : stack.pop
  end

  def place(stack)
    tag, name = stack.last
    return ".#{name}" if name

    up = stack[0...-1].reverse.find { |_, klass| klass }
    "#{".#{up[1]} " if up}#{tag}"
  end

  # @return [Array<Array(String, String)>] each rule of the page's style as its selector and body
  def rules
    style = File.read(css)[%r{<style>(.*?)</style>}m, 1].gsub(%r{/\*.*?\*/}m, "")
    style.scan(/([^{}]+)\{([^{}]*)\}/).flat_map do |heads, body|
      heads.split(",").map { |selector| [selector.strip, body] }
    end
  end

  def bounded?(selector)
    bodies = rules.select { |head, _| head.end_with?(selector) }.map(&:last)
    bodies.any? { |body| scrolls?(body) || clamped?(body) || ellipsized?(body) }
  end

  def scrolls?(body) = body.match?(/max-height:\s*\d/) && body.match?(/overflow:\s*(auto|scroll|hidden)/)

  def clamped?(body) = body.match?(/line-clamp:\s*\d/)

  def ellipsized?(body) = body.include?("white-space: nowrap") && body.include?("text-overflow: ellipsis")

  it "draws oversized text into every place the page is known to hold it", :aggregate_failures do
    expect(long_places(page)).to include(*places)
  end

  it "bounds every element that holds a long run of text", :aggregate_failures do
    long_places(page).each do |selector|
      expect(bounded?(selector)).to be(true), "#{selector} holds long text and has no height or line bound"
    end
  end

  it "bounds an epic's outcome closed and open", :aggregate_failures do
    expect(rules.find { |head, _| head == ".outcome" }.last).to include("nowrap", "ellipsis")
    expect(rules.find { |head, _| head == ".epic[open] .outcome" }.last).to match(/line-clamp:\s*4/)
  end
end
