module Hecks
  # A vendored, external bluebook: same shape as Framework, but for a
  # package that ships outside hecks's own lib/ (see .load! and .vendor!).
  module EmbryonautBluebook
    autoload :Lock, File.join(__dir__, "embryonaut_bluebook/lock")
    autoload :Manifest, File.join(__dir__, "embryonaut_bluebook/manifest")
    autoload :Registry, File.join(__dir__, "embryonaut_bluebook/registry")
    autoload :Shape, File.join(__dir__, "embryonaut_bluebook/shape")
    autoload :Vendor, File.join(__dir__, "embryonaut_bluebook/vendor")
    autoload :VendorCli, File.join(__dir__, "embryonaut_bluebook/vendor_cli")

    # The shape `hecks vendor` accepts for a package directory name. The name is joined into a
    # path that `load!` evaluates as Ruby, so `../x` or an absolute path must never reach it.
    PACKAGE_NAME = /\A[a-z][a-z0-9_]*\z/

    # Loads a vendored embryonaut bluebook package's `.bluebook` files, once
    # per registry.
    #
    # @param name [String, Symbol] the vendored package's directory name, such
    #   as `"payments"`
    # @param registry [Runtime::Registry, nil] the registry to vendor into and
    #   check for an existing load; defaults to the current boot registry
    # @return [String] the bluebook the package's bluebook declares (`"Documents"` for the
    #   `document` package), its directory name in Pascal case when no file declares one
    # @raise [Runtime::WiringError] if `registry` has no root, or no vendored
    #   package named `name` is checked out
    def self.load!(name, registry: Hecks.current_registry)
      check_loadable!(name, registry)
      dir = File.join(registry.root, "vendor", "embryonaut_bluebooks", name.to_s, "bluebook")
      # Loaded in the glob's alphabetical order; a package with several
      # files that reopen the same bluebook is named to rely on that.
      files = vendored_bluebooks(name, dir)
      chapter = Chapters.chapter_name(files.first) || Naming.pascal(name.to_s)
      load_package(files, dir) unless registry.bluebook(chapter)
      chapter
    end

    # Loads the package's bluebooks, then its plugin adapters, which answer its queries with the
    # wasm modules beside them.
    def self.load_package(files, dir)
      files.each { |file| Kernel.load(file) }
      Dir.glob(File.join(dir, "*.adapter")).each { |file| Kernel.load(file) }
    end
    private_class_method :load_package

    # @return [Array<String>] the package's vendored `.bluebook` files
    # @raise [Runtime::WiringError] if there are none
    def self.vendored_bluebooks(name, dir)
      files = Dir.glob(File.join(dir, "*.bluebook"))
      return files unless files.empty?

      raise Runtime::WiringError,
            "no vendored embryonaut bluebook named #{name.inspect} at #{dir} — " \
            "vendor it with hecks vendor #{name}"
    end
    private_class_method :vendored_bluebooks

    # @raise [Runtime::WiringError] if `registry` has no root to vendor from, or `name` is not a
    #   package name
    def self.check_loadable!(name, registry)
      unless registry&.root
        raise Runtime::WiringError,
              "attaches(#{name.inspect}, from: :vendor) needs a registry with a root to vendor from"
      end
      return if name.to_s.match?(PACKAGE_NAME)

      raise Runtime::WiringError,
            "attaches(#{name.inspect}, from: :vendor) is not a package name — it must match " \
            "[a-z][a-z0-9_]* (the name `hecks vendor` accepts)"
    end
    private_class_method :check_loadable!

    # Pins one package of the registry into a project's `vendor/` tree.
    #
    # @param name [String, Symbol] the package's directory name, such as `"payments"`
    # @param from [String] path of a local checkout of the registry repository
    # @param ref [String, nil] a release version (`"1.2.0"`), a release tag name, any
    #   commit-ish, or nil for the newest release
    # @param root [String] the consuming project's root
    # @param allow_downgrade [Boolean] whether a release older than the vendored one is allowed
    # @return [Vendor::Result] the commit, version and storage shape now vendored
    # @raise [Vendoring::Error] if the source, release or files are unusable, or a
    #   version-policy refusal applies (see Vendor)
    def self.vendor!(name, from:, root:, ref: nil, allow_downgrade: false)
      Vendor.new(name, from: from, root: root, ref: ref, allow_downgrade: allow_downgrade).call
    end
  end
end
