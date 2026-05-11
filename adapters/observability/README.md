# observability/

What the bus exposes about itself at runtime.

| Adapter | What |
|---|---|
| `logging/` | Structured log entry per command. Pre-bluebook. |
| `metrics/` | Counters + timings per command / event. Pre-bluebook. |
| `pii/` | PII marking + redaction policy for fields. Pre-bluebook. |
