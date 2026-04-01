package domain

import (
	"time"
)

type CancelOrder struct {
}

func (c CancelOrder) CommandName() string { return "CancelOrder" }

func (c CancelOrder) Execute(repo OrderRepository) (*Order, *CanceledOrder, error) {
	agg := NewOrder("", nil, "")
	agg.Status = "pending"
	if err := agg.Validate(); err != nil {
		return nil, nil, err
	}
	if err := repo.Save(agg); err != nil {
		return nil, nil, err
	}
	event := CanceledOrder{
		AggregateID: agg.ID,
		OccurredAt: time.Now(),
	}
	return agg, &event, nil
}
