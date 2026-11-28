require "tmpdir"
require "fileutils"

# A scratch checkout whose home domain (`lib/hecks/hecks`, the pizzas domain) attaches the Tenancy
# bluebook and keeps its Tenant aggregate in a SQLite store under a temporary directory, as the
# development checkout's overlay keeps the Tickets work items. One tenant is registered by a
# launcher-style boot, so a read of the attached directory has a kept row to find.
module HomeAttachedCheckout
  SLUG = "acme".freeze

  # Builds the checkout and the store, and points the cache home at a scratch directory.
  def open_checkout
    @saved = ENV.fetch("XDG_CACHE_HOME", nil)
    @checkout = Dir.mktmpdir("home-attached-checkout")
    @cache_home = Dir.mktmpdir("home-attached-cache")
    ENV["XDG_CACHE_HOME"] = @cache_home
    Hecks::CacheDir.reset!
    build_checkout
  end

  # Restores the cache home and removes the scratch directories.
  def close_checkout
    ENV["XDG_CACHE_HOME"] = @saved
    Hecks::CacheDir.reset!
    [@checkout, @cache_home, @store].compact.each { |dir| FileUtils.remove_entry(dir) }
  end

  # Copies the pizzas domain in as the home domain, binds the attached Tenancy store, and keeps
  # one tenant.
  def build_checkout
    home = File.join(@checkout, "lib/hecks/hecks")
    FileUtils.mkdir_p(File.dirname(home))
    FileUtils.cp_r(File.join(File.expand_path("../..", __dir__), "examples/pizzas"), home)
    File.write(File.join(@checkout, "lib/hecks/version.rb"), "VERSION = 1")
    bind_store(home)
    FileUtils.mkdir_p(File.join(@checkout, "lib/hecks/tenancy"))
    register_tenant(home)
  end

  # Writes the attachment, and the overlay files that bind Tenant to a store in the scratch tree.
  def bind_store(home)
    @store = Dir.mktmpdir("home-attached-store")
    hexagon = File.join(home, "bluebook/pizzas.hecksagon")
    File.write(hexagon, File.read(hexagon).sub('attaches "Governance"', "attaches \"Governance\"\n  attaches \"Tenancy\""))
    File.write(File.join(home, "bluebook/pizzas.local.hecksagon"),
               "Hecks.hecksagon \"Tenancy\" do\n  Tenancy::Tenant.persisted_by(\"SqlitePersistence\")\nend\n")
    File.write(File.join(home, "bluebook/pizzas.local.world"),
               "Hecks.world \"Tenancy\" do\n  persisted_by(\"SqlitePersistence\") " \
               "{ database #{File.join(@store, "kept.db").inspect} }\nend\n")
  end

  # A launcher-style boot of the home domain registers the tenant in the store, then ends.
  def register_tenant(home)
    runtime = Hecks.boot(File.join(home), install_driving: false)
    done = Hecks::Storehouse.dispatch(runtime: runtime, command: "tenancy tenant.register", summary: "spec",
                                      args: { "slug" => SLUG, "domain" => "acme.test", "realm" => "r", "schema" => "acme" })
    raise "the kept tenant was not registered: #{done[:error]}" unless done[:ok]
  end
end
