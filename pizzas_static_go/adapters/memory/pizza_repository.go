package memory

import (
	"sync"
	"pizzas_domain/domain"
)

type PizzaMemoryRepository struct {
	mu    sync.RWMutex
	store map[string]*domain.Pizza
}

func NewPizzaMemoryRepository() *PizzaMemoryRepository {
	return &PizzaMemoryRepository{store: make(map[string]*domain.Pizza)}
}

func (r *PizzaMemoryRepository) Find(id string) (*domain.Pizza, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	Pizza, ok := r.store[id]
	if !ok { return nil, nil }
	return Pizza, nil
}

func (r *PizzaMemoryRepository) Save(Pizza *domain.Pizza) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.store[Pizza.ID] = Pizza
	return nil
}

func (r *PizzaMemoryRepository) All() ([]*domain.Pizza, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make([]*domain.Pizza, 0, len(r.store))
	for _, v := range r.store { result = append(result, v) }
	return result, nil
}

func (r *PizzaMemoryRepository) Delete(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.store, id)
	return nil
}

func (r *PizzaMemoryRepository) Count() (int, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.store), nil
}
