package domain

import (
	"time"
)

type PlaceOrder struct {
	CustomerName string `json:"customer_name"`
	Quantity int64 `json:"quantity"`
}

func (c PlaceOrder) CommandName() string { return "PlaceOrder" }

func (c PlaceOrder) Execute(repo OrderRepository) (*Order, *PlacedOrder, error) {
	OrderItemItem, err := NewOrderItem(c.Quantity)
	if err != nil { return nil, nil, err }
	agg := NewOrder(c.CustomerName, []OrderItem{OrderItemItem}, "")
	agg.Status = "pending"
	if err := agg.Validate(); err != nil {
		return nil, nil, err
	}
	if err := repo.Save(agg); err != nil {
		return nil, nil, err
	}
	event := PlacedOrder{
		AggregateID: agg.ID,
		CustomerName: c.CustomerName,
		Quantity: c.Quantity,
		OccurredAt: time.Now(),
	}
	return agg, &event, nil
}
