package domain

type PizzaRepository interface {
	Find(id string) (*Pizza, error)
	Save(Pizza *Pizza) error
	All() ([]*Pizza, error)
	Delete(id string) error
	Count() (int, error)
}
