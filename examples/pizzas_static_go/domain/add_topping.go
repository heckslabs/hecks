package domain

import (
	"time"
)

type AddTopping struct {
	Name string `json:"name"`
	Amount int64 `json:"amount"`
}

func (c AddTopping) CommandName() string { return "AddTopping" }

func (c AddTopping) Execute(repo PizzaRepository) (*Pizza, *AddedTopping, error) {
	ToppingItem, err := NewTopping(c.Name, c.Amount)
	if err != nil { return nil, nil, err }
	agg := NewPizza(c.Name, "", []Topping{ToppingItem})
	if err := agg.Validate(); err != nil {
		return nil, nil, err
	}
	if err := repo.Save(agg); err != nil {
		return nil, nil, err
	}
	event := AddedTopping{
		AggregateID: agg.ID,
		Name: c.Name,
		Amount: c.Amount,
		OccurredAt: time.Now(),
	}
	return agg, &event, nil
}
