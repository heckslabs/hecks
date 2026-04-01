package domain

import (
	"time"
	"github.com/google/uuid"
)

type Order struct {
	ID string `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	CustomerName string `json:"customer_name"`
	Items []OrderItem `json:"items"`
	Status string `json:"status"`
}

func NewOrder(customerName string, items []OrderItem, status string) *Order {
	a := &Order{
		ID:        uuid.New().String(),
		CustomerName: customerName,
		Items: items,
		Status: status,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}
	return a
}

func (a *Order) Validate() error {
	if a.CustomerName == "" {
		return &ValidationError{Field: "customer_name", Message: "customer_name can't be blank"}
	}
	return nil
}
