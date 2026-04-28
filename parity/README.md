# parity/

*Parity* — here lives the contract between Ruby and Rust : the canonical IR shape, the fixture corpus, the known-drift list. Neither implementation owns it ; both must conform to it. Lifting parity to a top-level peer, *à côté* of *ruby/* and *rust/*, makes that role visible — the parity suite is **the nervous system that lets one know when the other moves**. Examples : *`parity/canonical_ir.rb`*, *`parity/fixtures/*.bluebook`*, *`parity/known_drift.txt`*. The lift from *`spec/parity/`* arrives in Round 1 (inbox i126).
