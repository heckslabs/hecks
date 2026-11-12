# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"

# What the planning page's speed specs build: Work item rows, a plan reading of them, a stand-in
# for the places a process could start, and a project folder holding one finished transcript.
module PlanPageSpeedKit
  TRAIN = { name: "T", state: "ok", count: "0", detail: "" }.freeze

  def refuse_processes
    allow(Open3).to receive(:capture3).and_raise("a request launched a process")
    allow(IO).to receive(:popen).and_raise("a request launched a process")
    allow(Process).to receive(:spawn).and_raise("a request launched a process")
  end

  def items(count)
    Array.new(count) do |index|
      { slug: "w-#{index}", title: "Title #{index}", status: "planned", area: ["lib/x"], priority: "", epic: "",
        yield_count: 0, reason: "", step: index, reviewed: [] }
    end
  end

  def reading(count)
    { strip: { running: [], next: [], held: [], landing: TRAIN, owner: [] },
      epics: [], no_epic: { count: count, groups: [["lib/x", items(count)]] } }
  end

  def projects_with_transcript
    Dir.mktmpdir.tap do |dir|
      FileUtils.mkdir_p(File.join(dir, "p"))
      line = JSON.generate(type: "assistant", message: { content: [{ type: "text", text: "Verdict: sound" }] })
      File.write(File.join(dir, "p", "abc123.jsonl"), "#{line}\n")
    end
  end
end
