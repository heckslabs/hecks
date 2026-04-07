package runtime

import (
	"encoding/json"
	"fmt"
	"pizzas_domain/domain"
	"pizzas_domain/adapters/memory"
)

type CommandResult struct {
	Aggregate interface{}
	Event     DomainEvent
}

type Application struct {
	PizzaRepo domain.PizzaRepository
	OrderRepo domain.OrderRepository
	EventBus   *EventBus
	CommandBus *CommandBus
}

func Boot() *Application {
	eventBus := NewEventBus()
	return &Application{
		PizzaRepo: memory.NewPizzaMemoryRepository(),
		OrderRepo: memory.NewOrderMemoryRepository(),
		EventBus:   eventBus,
		CommandBus: NewCommandBus(eventBus),
	}
}

func (app *Application) Run(commandName string, jsonAttrs []byte) (*CommandResult, error) {
	switch commandName {
	case "CreatePizza":
		var c domain.CreatePizza
		if err := json.Unmarshal(jsonAttrs, &c); err != nil {
			return nil, fmt.Errorf("decode %s: %w", commandName, err)
		}
		agg, event, err := c.Execute(app.PizzaRepo)
		if err != nil { return nil, err }
		app.EventBus.Publish(event)
		return &CommandResult{Aggregate: agg, Event: event}, nil
	case "AddTopping":
		var c domain.AddTopping
		if err := json.Unmarshal(jsonAttrs, &c); err != nil {
			return nil, fmt.Errorf("decode %s: %w", commandName, err)
		}
		agg, event, err := c.Execute(app.PizzaRepo)
		if err != nil { return nil, err }
		app.EventBus.Publish(event)
		return &CommandResult{Aggregate: agg, Event: event}, nil
	case "PlaceOrder":
		var c domain.PlaceOrder
		if err := json.Unmarshal(jsonAttrs, &c); err != nil {
			return nil, fmt.Errorf("decode %s: %w", commandName, err)
		}
		agg, event, err := c.Execute(app.OrderRepo)
		if err != nil { return nil, err }
		app.EventBus.Publish(event)
		return &CommandResult{Aggregate: agg, Event: event}, nil
	case "CancelOrder":
		var c domain.CancelOrder
		if err := json.Unmarshal(jsonAttrs, &c); err != nil {
			return nil, fmt.Errorf("decode %s: %w", commandName, err)
		}
		agg, event, err := c.Execute(app.OrderRepo)
		if err != nil { return nil, err }
		app.EventBus.Publish(event)
		return &CommandResult{Aggregate: agg, Event: event}, nil
	default:
		return nil, fmt.Errorf("unknown command: %s", commandName)
	}
}

func (app *Application) Events() []DomainEvent {
	return app.EventBus.Events()
}

func (app *Application) On(eventName string, handler func(DomainEvent)) {
	app.EventBus.Subscribe(eventName, handler)
}

func (app *Application) Repo(name string) interface{} {
	switch name {
	case "Pizza":
		return app.PizzaRepo
	case "Order":
		return app.OrderRepo
	default:
		return nil
	}
}
