# Go Module Registry

Generated Go modules self-register via `init()` for runtime discovery.

## What gets generated

### `runtime/registry.go`

A thread-safe central registry where domain packages register themselves:

```go
// ModuleInfo describes a registered domain module.
type ModuleInfo struct {
    Name       string
    Aggregates []string
    Commands   []string
    Boot       func(*Application)
}

// Register adds a domain module to the global registry.
func Register(info ModuleInfo)

// Modules returns a copy of all registered domain modules.
func Modules() map[string]ModuleInfo
```

### `domain/register.go` (per domain package)

Each domain package gets an `init()` that registers itself:

```go
package domain

import "pizzas_domain/runtime"

func init() {
    runtime.Register(runtime.ModuleInfo{
        Name:       "Pizzas",
        Aggregates: []string{"Pizza", "Order"},
        Commands:   []string{"CreatePizza", "UpdatePizza", "PlaceOrder"},
    })
}
```

## Usage (Go side)

```go
func main() {
    for name, info := range runtime.Modules() {
        fmt.Printf("Domain: %s, Aggregates: %v\n", name, info.Aggregates)
    }
}
```

## Multi-domain support

In multi-domain projects, each subdomain package registers independently:

```go
// pizzas/register.go
package pizzas

import "multi_domain/runtime"

func init() {
    runtime.Register(runtime.ModuleInfo{
        Name:       "Pizzas",
        Aggregates: []string{"Pizza"},
        Commands:   []string{"CreatePizza"},
    })
}

// orders/register.go
package orders

import "multi_domain/runtime"

func init() {
    runtime.Register(runtime.ModuleInfo{
        Name:       "Orders",
        Aggregates: []string{"Order"},
        Commands:   []string{"PlaceOrder"},
    })
}
```

## Ruby generators

- `GoHecks::RegistryGenerator` -- generates `runtime/registry.go`
- `GoHecks::RegisterGenerator` -- generates `register.go` per domain package
- Both are wired into `ProjectGenerator` and `MultiProjectGenerator` automatically
