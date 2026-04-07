package runtime

import (
	"sync"
	"time"
)

type DomainEvent interface {
	EventName() string
	GetOccurredAt() time.Time
}

type EventBus struct {
	mu        sync.RWMutex
	listeners map[string][]func(DomainEvent)
	global    []func(DomainEvent)
	events    []DomainEvent
}

func NewEventBus() *EventBus {
	return &EventBus{listeners: make(map[string][]func(DomainEvent))}
}

func (b *EventBus) Subscribe(eventName string, handler func(DomainEvent)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.listeners[eventName] = append(b.listeners[eventName], handler)
}

func (b *EventBus) OnAny(handler func(DomainEvent)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.global = append(b.global, handler)
}

func (b *EventBus) Publish(event DomainEvent) {
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

func (b *EventBus) Events() []DomainEvent {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.events
}

func (b *EventBus) Clear() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = nil
}
