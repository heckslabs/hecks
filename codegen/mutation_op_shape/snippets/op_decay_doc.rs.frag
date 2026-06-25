                // i106 — current * (1 - rate). Rate is the source-text
                // f64 (e.g. 0.05 → ×0.95). Decay composes with Clamp on
                // the same field — body math typically decays then clamps.
