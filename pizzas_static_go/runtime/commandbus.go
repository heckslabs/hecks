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
