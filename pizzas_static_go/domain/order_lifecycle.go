package domain

const (
	OrderStatusPending = "pending"
	OrderStatusCancelled = "cancelled"
)

func (o *Order) IsPending() bool { return a.Status == OrderStatusPending }
func (o *Order) IsCancelled() bool { return a.Status == OrderStatusCancelled }

func (o *Order) ValidTransition(target string) bool {
	switch {
	case target == "cancelled": return true
	default: return false
	}
}
