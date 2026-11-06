# frozen_string_literal: true

require "json"
require "open3"

# Runs the board's shared answer helper (answer.js) under node, with a stubbed window and
# sessionStorage as the pages load it, and returns what the steps pushed to `out`.
module AnswerNeedsNode
  WEB = File.expand_path("../../lib/hecks/pipeline_board/adapters/pipeline_web", __dir__)
  PRELUDE = <<~JS
    const store = {}; global.sessionStorage = { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v; } };
    global.window = {};
    const a = (require(%<path>s), window.boardAnswer), ask = (q, status = "blocked") => ({ id: "s1", status, detail: q });
    const out = [];
  JS

  def run_node(steps)
    script = "#{format(PRELUDE, path: File.join(WEB, "answer.js").to_json)}#{steps}\nconsole.log(JSON.stringify(out));"
    out, status = Open3.capture2("node", "-e", script)
    raise "node failed" unless status.success?

    JSON.parse(out)
  end

  def page_html(name)
    File.read(File.join(WEB, "#{name}.html"))
  end
end
