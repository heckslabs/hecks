module Hecks
  # A vendored, external bluebook: same shape as Framework, but for a
  # package that ships outside hecks's own lib/ (see .load! and .vendor!).
  module EmbryonautBluebook
    autoload :Lock, File.join(__dir__, "embryonaut_bluebook/lock")
    autoload :Shape, File.join(__dir__, "embryonaut_bluebook/shape")
    autoload :Vendor, File.join(__dir__, "embryonaut_bluebook/vendor")
    autoload :VendorCli, File.join(__dir__, "embryonaut_bluebook/vendor_cli")

    # Loads a vendored embryonaut bluebook package's `.bluebook` files, once
    # per registry.
    #
    # @param name [String, Symbol] the vendored package's directory name, such
    #   as `"payments"`
    # @param registry [Runtime::Registry, nil] the registry to vendor into and
    #   check for an existing load; defaults to the current boot registry
    # @return [void]
    # @raise [Runtime::WiringError] if `registry` has no root, or no vendored
    #   package named `name` is checked out
    def self.load!(name, registry: Hecks.current_registry)
      unless registry&.root
        raise Runtime::WiringError,
              "uses_embryonaut_bluebook(#{name.inspect}) needs a registry with a root to vendor from"
      end

      return if registry.bluebook(Naming.pascal(name.to_s))

      dir   = File.join(registry.root, "vendor", "embryonaut_bluebooks", name.to_s, "bluebook")
      files = Dir.glob(File.join(dir, "*.bluebook"))

      if files.empty?
        raise Runtime::WiringError,
              "no vendored embryonaut bluebook named #{name.inspect} at #{dir} — " \
              "vendor it with bin/vendor_bluebook #{name}"
      end

      # Loaded in the glob's alphabetical order; a package with several
      # files that reopen the same bluebook is named to rely on that.
      files.each { |file| Kernel.load(file) }
    end

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
