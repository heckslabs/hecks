package memory

import (
	"sync"
	"pizzas_domain/domain"
)

type OrderMemoryRepository struct {
	mu    sync.RWMutex
	store map[string]*domain.Order
}

func NewOrderMemoryRepository() *OrderMemoryRepository {
	return &OrderMemoryRepository{store: make(map[string]*domain.Order)}
}

func (r *OrderMemoryRepository) Find(id string) (*domain.Order, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	Order, ok := r.store[id]
	if !ok { return nil, nil }
	return Order, nil
}

func (r *OrderMemoryRepository) Save(Order *domain.Order) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.store[Order.ID] = Order
	return nil
}

func (r *OrderMemoryRepository) All() ([]*domain.Order, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make([]*domain.Order, 0, len(r.store))
	for _, v := range r.store { result = append(result, v) }
	return result, nil
}

func (r *OrderMemoryRepository) Delete(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.store, id)
	return nil
}

func (r *OrderMemoryRepository) Count() (int, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.store), nil
}
