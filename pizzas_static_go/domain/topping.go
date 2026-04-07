package domain

import "fmt"

type Topping struct {
	Name string `json:"name"`
	Amount int64 `json:"amount"`
}

func NewTopping(name string, amount int64) (Topping, error) {
	v := Topping{
		Name: name,
		Amount: amount,
	}
	// amount must be positive
	if v.Amount <= 0 {
		return Topping{}, fmt.Errorf("amount must be positive")
	}
	return v, nil
}
