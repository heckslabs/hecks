require "digest"
require "hecks"

# Loads a domain directory's declarations once per process and hands every later boot of the same
# unchanged directory its own copy, so the specs that boot per example don't re-evaluate every
# bluebook each time. A boot still gets a fresh Registry, its own runtime state and its own
# collections; only the loaded chapters, wiring and worlds are shared, and a changed file (path,
# size or mtime) is a different key. `HECKS_NO_DECLARATION_CACHE=1` turns it off. Specs only:
# production boot is untouched.
module DeclarationCache
  # @return [Hash] the copied declarations, by what produced them and the files they came from
  def self.cache = @cache ||= {}

  # @return [Array] what identifies the directory's files for the key. A directory under the system
  #   temp dir is a scratch copy with a name no other boot shares, so it is known by its files'
  #   relative paths and contents; any other is known by its files' paths, sizes and mtimes. The
  #   `vendor/embryonaut_bluebooks` tree beside the directory counts too, since `attaches ...,
  #   from: :vendor` loads from it: two copies differ when only their vendored packages do.
  def self.signature(directory)
    scratch = directory.start_with?(Dir.tmpdir)
    vendor  = File.join(File.dirname(directory), "vendor", "embryonaut_bluebooks", "**", "*")
    files   = Dir.glob(File.join(directory, "**", "*")) + Dir.glob(vendor)
    files.filter_map do |path|
      next unless File.file?(path)

      scratch ? [path.delete_prefix(File.dirname(directory)), Digest::MD5.file(path).hexdigest] : file_stamp(path)
    end.unshift(scratch ? :scratch : directory)
  end

  def self.file_stamp(path)
    stat = File.stat(path)
    [path, stat.size, stat.mtime.to_r]
  end

  # @param declared [Hecks::Runtime::Registry::Declarations] what a load gathered
  # @return [Hecks::Runtime::Registry::Declarations] the same collections, one level copied
  def self.copy(declared)
    Hecks::Runtime::Registry::Declarations.new(*declared.to_a.map { |collection| copy_collection(collection) })
  end

  def self.copy_collection(collection)
    case collection
    when Hash then collection.transform_values { |value| value.is_a?(Array) ? value.dup : value }
    when Array then collection.dup
    else collection
    end
  end

  # @return [Hecks::Runtime::Registry] a registry holding a copy of the cached declarations
  def self.registry_from(cached, root:)
    registry = Hecks::Runtime::Registry.new(root: root)
    registry.instance_variable_set(:@declared, copy(cached))
    registry
  end

  # Answers the registry for `key` from the cache, or loads it with the block and remembers it.
  def self.fetch(key, root:)
    if (cached = cache[key])
      registry_from(cached, root: root)
    else
      yield.tap { |loaded| cache[key] = copy(loaded.instance_variable_get(:@declared)) }
    end
  end

  # Prepended to Hecks::Runtime::Loader's singleton class.
  module Cached
    def load_declarations(loading, directory, shared, overlay)
      return super if ENV["HECKS_NO_DECLARATION_CACHE"]

      key = [shared, overlay, DeclarationCache.signature(directory)]
      DeclarationCache.fetch(key, root: File.dirname(directory)) { super }
    end
  end

  # Prepended to Hecks::Tools::SiteRoutes' singleton class, which builds a Registry of its own from a
  # project's `bluebook/` directory and loads it the same way.
  module CachedSiteRoutes
    def registry_for(root)
      directory = File.join(root, "bluebook")
      return super if ENV["HECKS_NO_DECLARATION_CACHE"] || !Dir.exist?(directory)

      key = [:site_routes, root, DeclarationCache.signature(directory)]
      DeclarationCache.fetch(key, root: root) { super }
    end
  end
end

Hecks::Runtime::Loader.singleton_class.prepend(DeclarationCache::Cached)

RSpec.configure do |config|
  config.before(:suite) do
    # The spec files that use SiteRoutes have required it by now; a run that loads none skips this.
    Hecks::Tools::SiteRoutes.singleton_class.prepend(DeclarationCache::CachedSiteRoutes) if defined?(Hecks::Tools::SiteRoutes)
  end
end
