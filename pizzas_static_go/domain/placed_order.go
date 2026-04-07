package domain

import "time"

type PlacedOrder struct {
	AggregateID string `json:"aggregate_id"`
	AggregateId string `json:"aggregate_id"`
	CustomerName string `json:"customer_name"`
	Quantity int64 `json:"quantity"`
	Items []OrderItem `json:"items"`
	Status string `json:"status"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (p PlacedOrder) EventName() string { return "PlacedOrder" }

func (p PlacedOrder) GetOccurredAt() time.Time { return e.OccurredAt }
