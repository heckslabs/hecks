# = Hecks::Conventions::ExtensionContract
#
# Enforces the required interface for Hecks extensions. Every extension
# must declare metadata via +Hecks.describe_extension+ and register a
# boot hook via +Hecks.register_extension+. The boot hook must accept
# three arguments: +domain_mod+, +domain+, and +runtime+.
#
# This contract validates that an extension module conforms to the
# standard shape by checking the extension registry and metadata registry.
#
#   result = Hecks::Conventions::ExtensionContract.validate(:logging)
#   result[:valid]   # => true
#   result[:missing] # => []
#
#   result = Hecks::Conventions::ExtensionContract.validate(:bogus)
#   result[:valid]   # => false
#   result[:missing] # => ["describe_extension not called for :bogus", ...]
#
module Hecks::Conventions
  module ExtensionContract
    # Required keys in the metadata hash returned by describe_extension.
    REQUIRED_META_KEYS = %i[description adapter_type wires_to].freeze

    # Valid adapter types for extensions.
    VALID_ADAPTER_TYPES = %i[driven driving].freeze

    # Expected arity of the boot hook block (domain_mod, domain, runtime).
    BOOT_HOOK_ARITY = 3

    # Return the expected shape of a conforming extension as a hash.
    # Useful for documentation and introspection.
    #
    # @return [Hash] the expected interface shape
    def self.shape
      {
        describe_extension: {
          required_keys: REQUIRED_META_KEYS,
          adapter_type: VALID_ADAPTER_TYPES,
        },
        register_extension: {
          boot_hook_arity: BOOT_HOOK_ARITY,
        },
      }
    end

    # Validate that a named extension conforms to the required interface.
    # Checks both the metadata registry (describe_extension) and the
    # extension registry (register_extension).
    #
    # @param name [Symbol] the extension name (e.g. :logging, :sqlite)
    # @return [Hash] { valid: Boolean, missing: Array<String> }
    def self.validate(name)
      missing = []

      meta = check_metadata(name, missing)
      check_boot_hook(name, missing)
      validate_meta_shape(meta, name, missing) if meta

      { valid: missing.empty?, missing: missing }
    end

    # Validate all registered extensions at once.
    # Returns a hash mapping extension names to their validation results.
    #
    # @return [Hash{Symbol => Hash}] name => { valid:, missing: }
    def self.validate_all
      names = all_extension_names
      names.each_with_object({}) do |name, results|
        results[name] = validate(name)
      end
    end

    # List all known extension names from both registries.
    #
    # @return [Array<Symbol>] sorted unique extension names
    def self.all_extension_names
      names = []
      names.concat(Hecks.extension_meta.map(&:first)) if Hecks.respond_to?(:extension_meta)
      names.concat(Hecks.extension_registry.map(&:first)) if Hecks.respond_to?(:extension_registry)
      names.uniq.sort
    end

    class << self
      private

      # Check that describe_extension was called for this name.
      def check_metadata(name, missing)
        return nil unless Hecks.respond_to?(:extension_meta)

        meta = Hecks.extension_meta[name]
        missing << "describe_extension not called for :#{name}" unless meta
        meta
      end

      # Check that register_extension was called and the hook has correct arity.
      def check_boot_hook(name, missing)
        return unless Hecks.respond_to?(:extension_registry)

        hook = Hecks.extension_registry[name]
        unless hook
          missing << "register_extension not called for :#{name}"
          return
        end

        unless hook.respond_to?(:arity)
          missing << "boot hook for :#{name} is not callable"
          return
        end

        if hook.arity != BOOT_HOOK_ARITY && hook.arity >= 0
          missing << "boot hook for :#{name} has arity #{hook.arity}, expected #{BOOT_HOOK_ARITY}"
        end
      end

      # Validate the shape of the metadata hash.
      def validate_meta_shape(meta, name, missing)
        REQUIRED_META_KEYS.each do |key|
          missing << "metadata for :#{name} missing :#{key}" unless meta.key?(key)
        end

        if meta[:adapter_type] && !VALID_ADAPTER_TYPES.include?(meta[:adapter_type])
          missing << "metadata for :#{name} has invalid adapter_type: #{meta[:adapter_type].inspect}"
        end
      end
    end
  end
end
