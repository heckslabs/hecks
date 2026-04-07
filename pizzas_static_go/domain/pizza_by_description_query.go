package domain

func PizzaByDescription(repo PizzaRepository, desc string) ([]*Pizza, error) {
	all, err := repo.All()
	if err != nil { return nil, err }
	return all, nil
}
