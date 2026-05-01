
# Hecks::Configuration::DomainLoader
#
# Loads domain definitions from installed gems or local paths.
# Gem loading requires the gem and reads Bluebook from it.
# Path loading builds the domain gem on the fly before loading.
#
#   domain "pizzas_domain"                  # from gem
#   domain "pizzas_domain", path: "domain/" # local, builds on boot
#
module Hecks
  class Configuration
    # Private mixin for Configuration that handles loading domain definitions
    # from either installed RubyGems or local filesystem paths. When loading
    # from a local path, the domain gem is built on the fly via +Hecks.build+
    # and its +lib/+ directory is added to +$LOAD_PATH+.
    #
    # Both loading strategies:
    # 1. Locate and evaluate the +Bluebook+ file to get the domain IR
    # 2. Set +source_path+ on the domain object for later reference
    # 3. Return a +[domain_obj, domain_module]+ tuple
    module DomainLoader
      include HecksTemplating::NamingHelpers
      private

      # Dispatches domain loading to the appropriate strategy based on whether
      # a +:path+ key is present in the domain entry.
      #
      # @param d [Hash] domain entry with :gem_name, :version, :path keys
      # @return [Array(Hecks::BluebookModel::Structure::Domain, Module)] tuple of domain IR and domain module
      def load_domain(d)
        d[:path] ? load_from_path(d) : load_from_gem(d)
      end

      # Loads a domain from a local filesystem path. Resolves the path relative
      # to Rails root (if Rails is defined) or the current working directory.
      # Evaluates +Bluebook+, builds the gem via +Hecks.build+, adds the
      # generated +lib/+ to +$LOAD_PATH+, and requires all generated files.
      #
      # @param d [Hash] domain entry with :gem_name and :path keys
      # @return [Array(Hecks::BluebookModel::Structure::Domain, Module)] tuple of domain IR and domain module
      def load_from_path(d)
        base = if defined?(::Rails)
                 ::Rails.root.join(d[:path]).to_s
               else
                 File.expand_path(d[:path])
               end

        domain_file = Dir[File.join(base, "*Bluebook")].first
        Kernel.load(domain_file)
        domain_obj = Hecks.last_domain
        domain_obj.source_path = domain_file

        gem_path = Hecks.build(domain_obj, output_dir: base)
        lib_path = File.join(gem_path, "lib")
        $LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
        require d[:gem_name]
        Dir[File.join(lib_path, "**/*.rb")].sort.each { |f| load f }
        domain_module = Object.const_get(bluebook_module_name(domain_obj.name))
        [domain_obj, domain_module]
      end

      # Loads a domain from an installed RubyGem. Optionally pins the gem version,
      # then requires it and locates the gem's +Bluebook+ for IR loading.
      # Falls back to Rails root or current directory if the gem spec is not found.
      #
      # @param d [Hash] domain entry with :gem_name and optional :version keys
      # @return [Array(Hecks::BluebookModel::Structure::Domain, Module)] tuple of domain IR and domain module
      def load_from_gem(d)
        gem d[:gem_name], d[:version] if d[:version]
        require d[:gem_name]

        gem_path = if Gem.loaded_specs[d[:gem_name]]
                     Gem.loaded_specs[d[:gem_name]].full_gem_path
                   elsif defined?(::Rails)
                     ::Rails.root.join(d[:gem_name]).to_s
                   else
                     File.join(Dir.pwd, d[:gem_name])
                   end

        domain_file = Dir[File.join(gem_path, "*Bluebook")].first
        Kernel.load(domain_file)
        domain_obj = Hecks.last_domain
        domain_obj.source_path = domain_file
        domain_module = Object.const_get(bluebook_module_name(domain_obj.name))
        [domain_obj, domain_module]
      end
    end
  end
end
