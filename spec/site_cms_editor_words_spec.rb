require "spec_helper"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The sentence a success notice says, run under node from the generated words.ts: the button's verb
# in the past tense, the thing it acted on after it, and a word the thing's name already says once.
EDITOR_WORDS_SCENARIO = <<~JS.freeze
  import { done, past } from "./editor/src/ui/words.ts";
  const cases = JSON.parse(process.env.CASES);
  const out = cases.map(([aggregate, command, creates]) => done({ name: aggregate }, { name: command, creates }));
  const participles = Object.fromEntries(JSON.parse(process.env.VERBS).map((verb) => [verb, past(verb)]));
  console.log(JSON.stringify({ out, participles }));
JS

RSpec.describe "the words of a success notice, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor") }
  let(:result) do
    env = { "CASES" => JSON.generate(CASES.map { |row| row.first(3) }), "VERBS" => JSON.generate(VERBS) }
    EditorNode.run(files, EDITOR_WORDS_SCENARIO, env: env)
  end

  CASES = [
    ["ScheduledAction", "Schedule", true, "Scheduled action."],
    ["ScheduledAction", "Reschedule", false, "Rescheduled."],
    ["ScheduledAction", "Cancel", false, "Canceled."],
    ["Article", "Publish", false, "Published."],
    ["Article", "Draft", true, "Drafted article."],
    ["Article", "SaveDraft", false, "Saved draft."],
    ["Article", "DiscardDraft", false, "Discarded draft."],
    ["Article", "Withdraw", false, "Withdrawn."],
    ["Article", "Start", true, "Started article."],
    ["Post", "Begin", true, "Begun post."],
    ["Post", "Publish", true, "Published post."],
    ["Order", "Submit", false, "Submitted."],
    ["Draft", "Draft", true, "Drafted."],
    ["MediaItem", "RegisterPicture", false, "Registered picture."]
  ].freeze

  PARTICIPLES = {
    "save" => "saved", "publish" => "published", "discard" => "discarded", "reschedule" => "rescheduled",
    "cancel" => "canceled", "withdraw" => "withdrawn", "start" => "started", "schedule" => "scheduled",
    "begin" => "begun", "reset" => "reset", "rewrite" => "rewritten", "undo" => "undone", "reply" => "replied", "log" => "logged"
  }.freeze
  VERBS = PARTICIPLES.keys.freeze

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  it "reads naturally for each verb and noun, and never says a word twice" do
    expect(result["out"]).to eq(CASES.map(&:last))
  end

  it "puts irregular and regular verbs in one past tense" do
    expect(result["participles"]).to eq(PARTICIPLES)
  end
end
