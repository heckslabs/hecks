package domain

import "time"

type CanceledOrder struct {
	AggregateID string `json:"aggregate_id"`
	AggregateId string `json:"aggregate_id"`
	CustomerName string `json:"customer_name"`
	Items []OrderItem `json:"items"`
	Status string `json:"status"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (c CanceledOrder) EventName() string { return "CanceledOrder" }

func (c CanceledOrder) GetOccurredAt() time.Time { return e.OccurredAt }
