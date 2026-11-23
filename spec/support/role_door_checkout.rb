require "tmpdir"
require "fileutils"
require "json"
require_relative "mcp_light_helper"
require "hecks/role_server_cache"

# A scratch checkout holding the pizzas domain as the Hecks domain and as a second one
# (`lib/hecks/tickets`), with the architect's routing cached, and a role's door started on it.
module RoleDoorCheckout
  include McpLightHelper

  # Builds the checkout and the cache, and points the cache home at a scratch directory.
  def open_checkout
    @saved = ENV.fetch("XDG_CACHE_HOME", nil)
    @checkout = Dir.mktmpdir("role-door-checkout")
    @cache_home = Dir.mktmpdir("role-door-cache")
    ENV["XDG_CACHE_HOME"] = @cache_home
    Hecks::CacheDir.reset!
    build_checkout
    Hecks::RoleServerCache.write(@checkout, { "architect" => ["order.create_pizza"] })
  end

  # Restores the cache home and removes the scratch directories.
  def close_checkout
    ENV["XDG_CACHE_HOME"] = @saved
    Hecks::CacheDir.reset!
    [@checkout, @cache_home].each { |dir| FileUtils.remove_entry(dir) }
  end

  def build_checkout
    FileUtils.mkdir_p(File.join(@checkout, "lib/hecks/agents"))
    File.write(File.join(@checkout, "lib/hecks/agents/agents.bluebook"), "rows")
    File.write(File.join(@checkout, "lib/hecks/version.rb"), "VERSION = 1")
    %w[hecks tickets].each do |name|
      FileUtils.cp_r(File.join(repo_root, "examples/pizzas"), File.join(@checkout, "lib/hecks", name))
    end
  end

  # @return [String] the text of the architect's door's answer to one tool call
  def answer(tool, arguments)
    env = { "HECKS_STOREHOUSE_ROOT" => @checkout, "XDG_CACHE_HOME" => @cache_home, "CLAUDE_CODE_AGENT" => "architect" }
    params = { "name" => tool, "arguments" => arguments }
    out, = run_raw(env, [{ "jsonrpc" => "2.0", "id" => 9, "method" => "tools/call", "params" => params }])
    JSON.parse(out.lines.last).dig("result", "content", 0, "text")
  end
end
