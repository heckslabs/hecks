require "open3"
require "tmpdir"
require "fileutils"
require "json"

# Runs the generated editor under node, with @hecks/client built from its TypeScript source into the
# sandbox's node_modules (node does not strip types under node_modules, so the client is
# transformed to plain modules first).
module EditorNode
  STRIP = <<~JS.freeze
    import { readdirSync, readFileSync, writeFileSync } from "node:fs";
    import { stripTypeScriptTypes } from "node:module";
    const [src, out] = process.argv.slice(2);
    for (const name of readdirSync(src).filter((file) => file.endsWith(".ts"))) {
      const code = stripTypeScriptTypes(readFileSync(`${src}/${name}`, "utf8"), { mode: "transform" });
      writeFileSync(`${out}/${name.replace(/\\.ts$/, ".mjs")}`, code.replace(/(from\\s+"\\.\\/[^"]+)\\.js"/g, '$1.mjs"'));
    }
  JS

  CLIENT = File.join(InMemoryDomain::ROOT, "packages/hecks-client")
  ENVIRONMENT = { "NODE_NO_WARNINGS" => "1" }.freeze

  module_function

  # @return [Boolean] whether node can strip TypeScript types, which the sandbox relies on
  def available?
    probe = 'process.exit(typeof require("node:module").stripTypeScriptTypes === "function" ? 0 : 1)'
    out, status = Open3.capture2e(ENVIRONMENT, "node", "-e", probe)
    status.success? && out.empty?
  rescue SystemCallError
    false
  end

  # @param files [Hash{String => String}] the editor's files, by path relative to its directory
  # @param scenario [String] the module run under node
  # @param env [Hash{String => String}] environment variables for the run, such as `TZ`
  # @return [Hash{String => Object}] what the scenario printed, parsed
  def run(files, scenario = EDITOR_NODE_SCENARIO, env: {})
    Dir.mktmpdir("cms_editor_node") do |dir|
      install_client(dir)
      files.each { |name, text| write(File.join(dir, "editor", name), text) }
      write(File.join(dir, "scenario.mjs"), scenario)
      out, err, status = Open3.capture3(ENVIRONMENT.merge(env), "node", File.join(dir, "scenario.mjs"))
      raise "the editor scenario failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  def install_client(dir)
    modules = File.join(dir, "node_modules/@hecks/client")
    FileUtils.mkdir_p(modules)
    write(File.join(dir, "strip.mjs"), STRIP)
    _, err, status = Open3.capture3(ENVIRONMENT, "node", File.join(dir, "strip.mjs"), File.join(CLIENT, "src"), modules)
    raise "could not prepare @hecks/client:\n#{err}" unless status.success?

    manifest = { "name" => "@hecks/client", "type" => "module", "exports" => "./index.mjs" }
    write(File.join(modules, "package.json"), JSON.generate(manifest))
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # The scenario's results, run once for the examples below.
  def results(files)
    @results ||= run(files)
  end

  # The results of the scenario for a chapter with no picture aggregate; the block gives its files.
  def bare_results
    @bare_results ||= run(yield, EDITOR_BARE_SCENARIO)
  end
end
