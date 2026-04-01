package domain

import "encoding/json"

type ValidationError struct {
	Field   string `json:"field"`
	Message string `json:"message"`
	Rule    string `json:"rule,omitempty"`
}

func (e *ValidationError) Error() string { return e.Message }

func (e *ValidationError) AsJSON() []byte {
	b, _ := json.Marshal(e)
	return b
}

type GuardRejected struct {
	Command   string `json:"command"`
	Aggregate string `json:"aggregate,omitempty"`
	Message   string `json:"message"`
}

func (e *GuardRejected) Error() string { return e.Message }

type GateAccessDenied struct {
	Role    string `json:"role"`
	Action  string `json:"action"`
	Message string `json:"message"`
}

func (e *GateAccessDenied) Error() string { return e.Message }
