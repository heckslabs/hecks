require "fileutils"
require "json"
require_relative "mcp_light_helper"

# What the `run` tool's spec needs: a scratch pizzas domain on Memory with a command that declares
# `confirm`, the `run` call itself, and a server's replies by request id.
module McpRunHelper
  include McpLightHelper

  # A command the scratch domain adds before `CreatePizza`: it declares `confirm`.
  DISCARD_MENU = <<~RUBY.gsub(/^/, "    ").freeze
    command "DiscardMenu" do
      goal "Take every pizza off the menu"
      attribute :name, PizzaName
      attribute :confirm, Boolean, default: false
      sets :name
    end

    command "CreatePizza" do
  RUBY

  # Copies the pizzas domain under `sandbox` as `pizzas`, on Memory, with `DiscardMenu` added.
  def scratch_pizzas(sandbox)
    target = File.join(sandbox, "pizzas")
    FileUtils.cp_r(File.join(repo_root, "examples/pizzas/bluebook"), target)
    FileUtils.rm_f(File.join(target, "pizzas.world"))
    rewrite(File.join(target, "pizzas.hecksagon")) { |text| text.gsub('persisted_by("Postgres")', 'persisted_by("Memory")') }
    rewrite(File.join(target, "pizzas.bluebook")) { |text| text.sub(/^    command "CreatePizza" do\n/, DISCARD_MENU) }
  end

  def rewrite(path) = File.write(path, yield(File.read(path)))

  def run_call(id, command, **extra)
    { "jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
      "params" => { "name" => "run", "arguments" => { "command" => command, "summary" => "spec" }.merge(extra) } }
  end

  def pizza_args = { "name" => { "value" => "Margherita" }, "pizza" => { "price_cents" => 1200, "size" => "large" } }

  # Starts a server with `env` on `requests` and answers its results by request id.
  def answers(env, requests)
    out, = run_raw(env, requests)
    out.lines.map { |line| JSON.parse(line) }.to_h { |reply| [reply["id"], reply["result"]] }
  end

  def payload(result) = JSON.parse(result["content"].first["text"])

  def tool_names(result) = result["tools"].map { |tool| tool["name"] }

  def list_request = { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }
end
