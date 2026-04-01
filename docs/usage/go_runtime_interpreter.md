# Go Runtime Interpreter

The Go runtime interpreter generates an `Application` struct that boots
the domain at runtime, wires up repositories and event infrastructure,
and dispatches commands by name -- mirroring the Ruby `Hecks::Runtime`.

## Generated Code

When you run `hecks build --target go`, the generator produces
`runtime/application.go` alongside the existing `eventbus.go` and
`commandbus.go`.

## Usage in Generated Go Code

```go
package main

import (
    "encoding/json"
    "fmt"
    "pizzas_domain/runtime"
)

func main() {
    // Boot the domain -- wires memory repos, event bus, command bus
    app := runtime.Boot()

    // Execute a command by name with JSON attributes
    attrs, _ := json.Marshal(map[string]interface{}{
        "name": "Margherita",
    })
    result, err := app.Run("CreatePizza", attrs)
    if err != nil {
        panic(err)
    }

    fmt.Printf("Created: %+v\n", result.Aggregate)
    fmt.Printf("Event: %s\n", result.Event.EventName())

    // Subscribe to events
    app.On("CreatedPizza", func(e runtime.DomainEvent) {
        fmt.Println("Pizza created!")
    })

    // Check event history
    fmt.Printf("Total events: %d\n", len(app.Events()))

    // Access a repository by name
    repo := app.Repo("Pizza")
    fmt.Printf("Repo type: %T\n", repo)
}
```

## API

| Method | Signature | Description |
|--------|-----------|-------------|
| `Boot` | `func Boot() *Application` | Creates an Application with memory repos and wired buses |
| `Run` | `func (app *Application) Run(commandName string, jsonAttrs []byte) (*CommandResult, error)` | Dispatches a command by name, returns aggregate + event |
| `Events` | `func (app *Application) Events() []DomainEvent` | Returns all published domain events |
| `On` | `func (app *Application) On(eventName string, handler func(DomainEvent))` | Subscribes to a specific event type |
| `Repo` | `func (app *Application) Repo(name string) interface{}` | Looks up a repository by aggregate name |

## CommandResult

```go
type CommandResult struct {
    Aggregate interface{}    // The created or updated aggregate
    Event     DomainEvent    // The domain event that was published
}
```
