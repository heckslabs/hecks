package domain

type OrderRepository interface {
	Find(id string) (*Order, error)
	Save(Order *Order) error
	All() ([]*Order, error)
	Delete(id string) error
	Count() (int, error)
}
