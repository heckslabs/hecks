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
