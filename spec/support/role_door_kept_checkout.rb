require "tmpdir"
require "fileutils"
require "json"
require_relative "role_door_checkout"

# A scratch checkout whose home domain (`lib/hecks/hecks`) attaches the Tenancy bluebook and keeps
# its Tenant aggregate in a SQLite store under a temporary directory, as the development
# checkout's overlay keeps the Tickets work items. One tenant is registered by a launcher-style
# boot, and a role's door, started as the real door starts it, is asked to read it back.
module RoleDoorKeptCheckout
  include RoleDoorCheckout

  SLUG = "acme".freeze

  # The environment the real door sets: restricted to commands, the checkout's domains, Memory.
  def door_env
    { "HECKS_STOREHOUSE_ROOT"  => @checkout, "XDG_CACHE_HOME" => @cache_home, "CLAUDE_CODE_AGENT" => "architect",
      "HECKS_SERVER_TOOLS"     => "commands", "HECKS_SERVER_DOMAINS" => File.join(@checkout, "lib/hecks"),
      "HECKS_SERVER_COMMANDS"  => "order.create_pizza", "HECKS_ENVIRONMENT" => "memory" }
  end

  # @return [String] the text of the door's answer to one tool call, in the real door's setting
  def door_answer(tool, arguments)
    params = { "name" => tool, "arguments" => arguments }
    out, = run_raw(door_env, [{ "jsonrpc" => "2.0", "id" => 9, "method" => "tools/call", "params" => params }])
    JSON.parse(out.lines.last).dig("result", "content", 0, "text")
  end

  # Builds the checkout with the home attaching Tenancy, its store bound, and one tenant kept.
  def build_checkout
    super
    home = File.join(@checkout, "lib/hecks/hecks")
    bind_store(home)
    FileUtils.mkdir_p(File.join(@checkout, "lib/hecks/tenancy"))
    register_tenant(home)
  end

  # Writes the attachment, and the overlay files that bind Tenant to a store in the scratch tree.
  def bind_store(home)
    @store = Dir.mktmpdir("role-door-store")
    hexagon = File.join(home, "bluebook/pizzas.hecksagon")
    File.write(hexagon, File.read(hexagon).sub('attaches "Governance"', "attaches \"Governance\"\n  attaches \"Tenancy\""))
    File.write(File.join(home, "bluebook/pizzas.local.hecksagon"),
               "Hecks.hecksagon \"Tenancy\" do\n  Tenancy::Tenant.persisted_by(\"SqlitePersistence\")\nend\n")
    File.write(File.join(home, "bluebook/pizzas.local.world"),
               "Hecks.world \"Pizzas\" do\n  persisted_by(\"SqlitePersistence\") { database #{File.join(@store, "kept.db").inspect} }\nend\n")
  end

  # A launcher-style boot of the home domain registers the tenant in the store, then ends.
  def register_tenant(home)
    runtime = Hecks.boot(File.join(home), install_driving: false)
    Hecks::Storehouse.dispatch(runtime: runtime, command: "tenancy register", summary: "spec",
                               args: { "slug" => SLUG, "domain" => "acme.test", "realm" => "r", "schema" => "acme" })
  end

  def close_checkout
    super
    FileUtils.remove_entry(@store) if @store
  end
end
