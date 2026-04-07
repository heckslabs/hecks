# GoHecks::RegistryGenerator
#
# Generates runtime/registry.go — a thread-safe module registry for
# Go runtime discovery. Domains self-register via init() and the
# registry exposes all registered modules at runtime.
#
#   gen = RegistryGenerator.new
#   gen.generate  # => Go source string for runtime/registry.go
#
module GoHecks
  class RegistryGenerator
    def generate
      <<~'GO'
        package runtime

        import "sync"

        // ModuleInfo describes a registered domain module.
        type ModuleInfo struct {
        	Name       string
        	Aggregates []string
        	Commands   []string
        	Boot       func(*Application)
        }

        var (
        	registryMu sync.RWMutex
        	modules    = make(map[string]ModuleInfo)
        )

        // Register adds a domain module to the global registry.
        // Typically called from an init() function in each domain package.
        func Register(info ModuleInfo) {
        	registryMu.Lock()
        	defer registryMu.Unlock()
        	modules[info.Name] = info
        }

        // Modules returns a copy of all registered domain modules.
        func Modules() map[string]ModuleInfo {
        	registryMu.RLock()
        	defer registryMu.RUnlock()
        	result := make(map[string]ModuleInfo, len(modules))
        	for k, v := range modules {
        		result[k] = v
        	}
        	return result
        }
      GO
    end
  end
end
