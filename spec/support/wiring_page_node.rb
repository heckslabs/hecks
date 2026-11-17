# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

# Runs the wiring page's script under node against a fake document and
# reads back what a scenario prints.
module WiringPageNode
  PAGE = File.expand_path("../../lib/hecks/pipeline_board/adapters/pipeline_web/wiring.html", __dir__)
  HARNESS = File.expand_path("wiring_page_harness.js", __dir__)

  module_function

  # @param scenario [String] JS run with the page's functions and state (`fire`, `applyWiring`,
  #   `enter`, `units`, `links`, `edges`, `said`) in scope; its last expression is the result
  # @return [Object] the scenario's result, parsed from JSON
  def run(scenario)
    Dir.mktmpdir("wiring_page") do |dir|
      path = File.join(dir, "scenario.js")
      File.write(path, scenario)
      out, err, status = Open3.capture3({ "NODE_NO_WARNINGS" => "1" }, "node", HARNESS, PAGE, path)
      raise "the wiring page scenario failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end
end
