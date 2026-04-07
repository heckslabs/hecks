package domain

import (
	"time"
	"github.com/google/uuid"
)

type Pizza struct {
	ID string `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	Name string `json:"name"`
	Description string `json:"description"`
	Toppings []Topping `json:"toppings"`
}

func NewPizza(name string, description string, toppings []Topping) *Pizza {
	a := &Pizza{
		ID:        uuid.New().String(),
		Name: name,
		Description: description,
		Toppings: toppings,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}
	return a
}

func (a *Pizza) Validate() error {
	if a.Name == "" {
		return &ValidationError{Field: "name", Message: "name can't be blank"}
	}
	if a.Description == "" {
		return &ValidationError{Field: "description", Message: "description can't be blank"}
	}
	return nil
}
