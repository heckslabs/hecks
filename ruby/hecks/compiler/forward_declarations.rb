# Hecks::Compiler::ForwardDeclarations
#
# Generates forward declarations and early extensions needed in the
# bundled binary. In the interpreted runtime, hecks.rb orchestrates
# load order so registries extend before chapters load. In the bundle,
# all files are flattened, so we inject these declarations early.
#
#   ForwardDeclarations.write(io)
#   ForwardDeclarations.write_registry_extends(io)
#
module Hecks
  module Compiler
    module ForwardDeclarations
      # Writes forward declarations for modules whose children appear
      # before their parent in $LOADED_FEATURES.
      def self.write(io)
        io.puts "# Forward declarations for load-order dependencies"
        io.puts DEPRECATIONS_STUB
        io.puts ""
      end

      # Writes the registry extend calls that normally live in hecks.rb.
      # Must be injected after registry modules are defined but before
      # chapter-loaded files that call register methods.
      def self.write_registry_extends(io)
        io.puts REGISTRY_EXTENDS
      end

      DEPRECATIONS_STUB = <<~'RUBY'
        module HecksDeprecations
          @registry = []
          def self.register(target_class, method_name, &shim)
            mod = Module.new { define_method(method_name, &shim) }
            target_class.prepend(mod)
            @registry << { target: target_class, method: method_name }
          end
          def self.registered = @registry.dup
          def self.warn_deprecated(klass, method)
            warn "[DEPRECATION] #{klass}##{method} is deprecated."
          end
        end
      RUBY

      REGISTRY_EXTENDS = <<~'RUBY'
        # Early registry extension (from hecks.rb)
        module Hecks
          extend ExtensionRegistryMethods
          extend CapabilityRegistryMethods
          extend DomainRegistryMethods
          extend CrossDomainMethods
          extend ThreadContextMethods
          extend TargetRegistryMethods
          extend AdapterRegistryMethods
          extend ValidationRegistryMethods
          extend DumpFormatRegistryMethods
          extend GrammarRegistryMethods
        end
      RUBY
    end
  end
end
