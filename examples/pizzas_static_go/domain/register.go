package domain

import "pizzas_domain/runtime"

func init() {
	runtime.Register(runtime.ModuleInfo{
		Name:       "Pizzas",
		Aggregates: []string{"Pizza", "Order"},
		Commands:   []string{"CreatePizza", "AddTopping", "PlaceOrder", "CancelOrder"},
	})
}
