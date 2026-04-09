# Hecks::Runtime::ExtensionDispatch
#
# Applies extensions and capabilities to a live runtime. Extensions add
# infrastructure behavior; capabilities enrich the domain IR.
#
#   runtime.extend(:logging)
#   runtime.capability(:crud)
#
module Hecks
  class Runtime
    # Hecks::Runtime::ExtensionDispatch
    #
    # Applies extensions and capabilities to a live runtime without rebooting.
    #
    module ExtensionDispatch
      # Apply an extension to the live runtime without rebooting.
      #
      # @param name [Symbol] the registered extension name
      # @param kwargs [Hash] extension-specific options
      # @return [void]
      def extend(name, **kwargs)
        if Hecks.extension_registry.empty?
          require "hecks/runtime/load_extensions"
          Hecks::LoadExtensions.require_all
        end
        hook = Hecks.extension_registry[name.to_sym]
        raise "Unknown extension: #{name}. Available: #{Hecks.extension_registry.keys.join(', ')}" unless hook
        if kwargs.any? && @mod.respond_to?(:connections)
          @mod.connections[:sends] << { name: name.to_sym, **kwargs }
        end
        hook.call(@mod, @domain, self, **kwargs)
        puts "  \e[32m✓\e[0m #{name}"
      end

      # Apply a capability to the live runtime, enriching the domain IR.
      #
      # @param name [Symbol] the registered capability name
      # @return [void]
      def capability(name)
        load_capability(name)
        hook = Hecks.capability_registry[name.to_sym]
        raise "Unknown capability: #{name}. Available: #{Hecks.capability_registry.keys.join(', ')}" unless hook
        hook.call(self)
      end

      def load_capability(name)
        require "hecks/capabilities/#{name}"
      rescue LoadError
        require "hecks/concerns/#{name}"
      end

      private

      # Apply capabilities declared in the Hecksagon file.
      # Stores exclusions so composite capabilities can check them.
      # Port-only declarations (driving/driven without a capability file) are skipped.
      def apply_hecksagon_capabilities
        return unless @hecksagon
        excluded = @hecksagon.excluded_capabilities || []
        Hecks.instance_variable_set(:@_excluded_capabilities, excluded)

        # Apply individual capabilities
        (@hecksagon.capabilities || []).each do |cap|
          next if excluded.include?(cap)
          begin
            capability(cap)
          rescue LoadError, RuntimeError
            # Skip capabilities that don't have implementation files yet
          end
        end

        # Apply concerns (bundles of capabilities)
        (@hecksagon.concerns || []).each do |concern_name|
          next if excluded.include?(concern_name)
          begin
            load_capability(concern_name)
            hook = Hecks.capability_registry[concern_name.to_sym]
            hook.call(self) if hook
          rescue LoadError, RuntimeError
          end
        end

        Hecks.instance_variable_set(:@_excluded_capabilities, [])
      end
    end
  end
end
