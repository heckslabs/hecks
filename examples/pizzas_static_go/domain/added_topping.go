package domain

import "time"

type AddedTopping struct {
	AggregateID string    `json:"aggregate_id"`
	AggregateId string `json:"aggregate_id"`
	Name string `json:"name"`
	Amount int64 `json:"amount"`
	Description string `json:"description"`
	Toppings []Topping `json:"toppings"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e AddedTopping) EventName() string { return "AddedTopping" }

func (e AddedTopping) GetOccurredAt() time.Time { return e.OccurredAt }
