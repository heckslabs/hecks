# GoHecks::RuntimeGenerator
#
# Generates the Go runtime package: event bus, command bus, and domain
# event interface. Projected from the Ruby hecks_runtime equivalents.
#
module GoHecks
  class RuntimeGenerator
    def generate_event_bus
      <<~'GO'
        package runtime

        import (
        	"sync"
        	"time"
        )

        type BluebookEvent interface {
        	EventName() string
        	GetOccurredAt() time.Time
        }

        type EventBus struct {
        	mu        sync.RWMutex
        	listeners map[string][]func(BluebookEvent)
        	global    []func(BluebookEvent)
        	events    []BluebookEvent
        }

        func NewEventBus() *EventBus {
        	return &EventBus{listeners: make(map[string][]func(BluebookEvent))}
        }

        func (b *EventBus) Subscribe(eventName string, handler func(BluebookEvent)) {
        	b.mu.Lock()
        	defer b.mu.Unlock()
        	b.listeners[eventName] = append(b.listeners[eventName], handler)
        }

        func (b *EventBus) OnAny(handler func(BluebookEvent)) {
        	b.mu.Lock()
        	defer b.mu.Unlock()
        	b.global = append(b.global, handler)
        }

        func (b *EventBus) Publish(event BluebookEvent) {
        	b.mu.Lock()
        	b.events = append(b.events, event)
        	b.mu.Unlock()

        	b.mu.RLock()
        	defer b.mu.RUnlock()
        	for _, h := range b.listeners[event.EventName()] {
        		h(event)
        	}
        	for _, h := range b.global {
        		h(event)
        	}
        }

        func (b *EventBus) Events() []BluebookEvent {
        	b.mu.RLock()
        	defer b.mu.RUnlock()
        	return b.events
        }

        func (b *EventBus) Clear() {
        	b.mu.Lock()
        	defer b.mu.Unlock()
        	b.events = nil
        }
      GO
    end

    def generate_command_bus
      <<~'GO'
        package runtime

        type Middleware func(command interface{}, next func() error) error

        type CommandBus struct {
        	middleware []Middleware
        	EventBus   *EventBus
        }

        func NewCommandBus(eventBus *EventBus) *CommandBus {
        	return &CommandBus{EventBus: eventBus}
        }

        func (b *CommandBus) Use(mw Middleware) {
        	b.middleware = append(b.middleware, mw)
        }

        func (b *CommandBus) Dispatch(command interface{}, core func() error) error {
        	chain := core
        	for i := len(b.middleware) - 1; i >= 0; i-- {
        		mw := b.middleware[i]
        		next := chain
        		chain = func() error { return mw(command, next) }
        	}
        	return chain()
        }
      GO
    end
  end
end
