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
        puts "#{name} extension applied"
      end

      # Apply a capability to the live runtime, enriching the domain IR.
      #
      # @param name [Symbol] the registered capability name
      # @return [void]
      def capability(name)
        require "hecks/capabilities/#{name}"
        hook = Hecks.capability_registry[name.to_sym]
        raise "Unknown capability: #{name}. Available: #{Hecks.capability_registry.keys.join(', ')}" unless hook
        hook.call(self)
      end

      private

      # Apply capabilities declared in the Hecksagon file.
      def apply_hecksagon_capabilities
        return unless @hecksagon
        (@hecksagon.capabilities || []).each { |cap| capability(cap) }
      end
    end
  end
end
