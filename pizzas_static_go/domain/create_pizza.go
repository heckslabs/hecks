package domain

import (
	"time"
)

type CreatePizza struct {
	Name string `json:"name"`
	Description string `json:"description"`
}

func (c CreatePizza) CommandName() string { return "CreatePizza" }

func (c CreatePizza) Execute(repo PizzaRepository) (*Pizza, *CreatedPizza, error) {
	agg := NewPizza(c.Name, c.Description, nil)
	if err := agg.Validate(); err != nil {
		return nil, nil, err
	}
	if err := repo.Save(agg); err != nil {
		return nil, nil, err
	}
	event := CreatedPizza{
		AggregateID: agg.ID,
		Name: c.Name,
		Description: c.Description,
		OccurredAt: time.Now(),
	}
	return agg, &event, nil
}
