package domain

import "fmt"

type OrderItem struct {
	Quantity int64 `json:"quantity"`
}

func NewOrderItem(quantity int64) (OrderItem, error) {
	v := OrderItem{
		Quantity: quantity,
	}
	// quantity must be positive
	if v.Quantity <= 0 {
		return OrderItem{}, fmt.Errorf("quantity must be positive")
	}
	return v, nil
}
