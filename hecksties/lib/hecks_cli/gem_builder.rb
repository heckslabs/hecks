require "bundler"
  # Hecks::GemBuilder
  #
  # Builds and installs all Hecks component gems from their subdirectories,
  # then the meta-gem. Each component is built from its own directory so that
  # Dir globs in gemspecs resolve correctly.
  #
  #   builder = Hecks::GemBuilder.new("/path/to/hecks")
  #   builder.build      # build all .gem files
  #   builder.install    # build + install all gems
  #

module Hecks
  class GemBuilder
    # Discover components by finding directories with gemspecs
    def self.discover_components(root)
      Dir[File.join(root, "*/")].filter_map do |dir|
        name = File.basename(dir)
        next if name == "examples" || name.start_with?(".")
        gemspec = File.join(dir, "#{name}.gemspec")
        name if File.exist?(gemspec)
      end.sort
    end

    COMPONENTS = discover_components(File.expand_path("../../..", __dir__)).freeze

    attr_reader :root

    # @param root [String] path to the hecks project root (must contain hecks.gemspec)
    # @param output [#call] callback for status messages, receives (message, color)
    def initialize(root, output: method(:default_output))
      @root = root
      @output = output
    end

    # Builds all component gems and the meta-gem. Auto-increments the
    # CalVer version before building.
    #
    # @return [Boolean] true if all builds succeeded
    def build
      bump_version!
      COMPONENTS.each do |name|
        next if skip_missing?(name)
        return false unless build_component(name)
      end
      @output.call("Building hecks meta-gem...", :green)
      Dir.chdir(root) { unbundled_system("gem build hecks.gemspec") }
    end

    # Builds and installs all component gems, then the meta-gem.
    # Builds all gems first, then installs in dependency order so each
    # gem's dependencies are already installed when it's reached.
    #
    # @return [Boolean] true if all builds and installs succeeded
    def install
      bump_version!
      gem_files = {}
      present = COMPONENTS.select { |n| !skip_missing?(n) }
      present.each do |name|
        gem_file = build_for_install(name)
        return false unless gem_file
        gem_files[name] = gem_file
      end
      @output.call("Building hecks meta-gem...", :green)
      Dir.chdir(root) do
        return build_failed("hecks") unless unbundled_system("gem build hecks.gemspec")
        gem_file = newest_gem("hecks")
        return build_failed("hecks") unless gem_file
        gem_files["hecks"] = File.expand_path(gem_file)
      end
      sorted = topo_sort(present)
      @output.call("Installing in dependency order...", :green)
      sorted.each do |name|
        path = gem_files[name]
        unless unbundled_system("gem install --local #{path}")
          return install_failed(name)
        end
        File.delete(path)
        @output.call("Installed #{File.basename(path)}", :green)
      end
      meta = gem_files["hecks"]
      return install_failed("hecks") unless unbundled_system("gem install --local #{meta}")
      File.delete(meta)
      @output.call("Installed #{File.basename(meta)}", :green)
      true
    end

    private

    def bump_version!
      versioner = Hecks::Versioner.new(root)
      new_version = versioner.next
      version_file = File.join(root, "hecksties", "lib", "hecks", "version.rb")
      content = File.read(version_file)
      updated = content.gsub(/VERSION = ".*"/, "VERSION = \"#{new_version}\"")
      File.write(version_file, updated)
      @output.call("Version: #{new_version}", :green)
    end

    def component_dir(name)
      File.join(root, name)
    end

    def gemspec_path(name)
      File.join(component_dir(name), "#{name}.gemspec")
    end

    def skip_missing?(name)
      unless File.exist?(gemspec_path(name))
        @output.call("Skipping #{name} (no gemspec)", :yellow)
        true
      end
    end

    def build_component(name)
      @output.call("Building #{name}...", :green)
      Dir.chdir(component_dir(name)) do
        return build_failed(name) unless unbundled_system("gem build #{name}.gemspec")
        Dir["#{name}-*.gem"].each { |f| File.delete(f) }
      end
      true
    end

    def build_for_install(name)
      @output.call("Building #{name}...", :green)
      Dir.chdir(component_dir(name)) do
        return nil unless unbundled_system("gem build #{name}.gemspec")
        gem_file = newest_gem(name)
        return nil unless gem_file
        File.expand_path(gem_file)
      end
    end

    def newest_gem(name)
      Dir["#{name}-*.gem"].max_by { |f| File.mtime(f) }
    end

    def topo_sort(names)
      set = names.to_set
      deps = {}
      names.each do |name|
        spec = Gem::Specification.load(gemspec_path(name))
        deps[name] = if spec
                        spec.runtime_dependencies.map(&:name).select { |d| set.include?(d) }
                      else
                        []
                      end
      end
      sorted = []
      visited = {}
      visit = ->(n) do
        return if visited[n]
        visited[n] = true
        deps[n].each { |d| visit.call(d) }
        sorted << n
      end
      names.each { |n| visit.call(n) }
      sorted
    end

    def build_failed(name)
      @output.call("Build failed for #{name}", :red)
      false
    end

    def install_failed(name)
      @output.call("Install failed for #{name}", :red)
      false
    end

    def unbundled_system(*cmd)
      Bundler.with_unbundled_env { system(*cmd) }
    end

    def default_output(message, _color = nil)
      puts message
    end
  end
end
