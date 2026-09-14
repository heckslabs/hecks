placeholder — a sibling file living beside a root-shaped domain's own
entry point (embryonautfoundersapp's real bluebook/ directory carries
adapters/ and translations/ the same way). Deliberately NOT named
`translations/`: a directory by that exact name under `bluebook/` is
itself a real corpus route (`Hecks::Corpus::ROUTES`, matched by
`spec/translation/committed_edges_spec.rb`), so a fixture domain that
isn't wired with a real translation edge must not carry one — see this
fixture's own git history for the failure that taught this.
