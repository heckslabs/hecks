package domain

func OrderPending(repo OrderRepository) ([]*Order, error) {
	all, err := repo.All()
	if err != nil { return nil, err }
	return all, nil
}
