    /// The verdict DATA a conforming handler must emit on stdout (k=v lines)
    /// for this port — the OUTPUT half of the contract, symmetric with
    /// `fields` (the INPUT half it reads from `.world`). Declared once on the
    /// family ; every adapter's handler produces them (payment -> payment_ref).
    /// A conformance test asserts the handler actually emits them. Parsed from
    /// the `produces :name` lines of the `*.family` declaration.
