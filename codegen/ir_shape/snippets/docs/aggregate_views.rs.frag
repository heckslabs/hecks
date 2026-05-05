    /// i254 — views per role. Each `View` declares a named projection
    /// of this aggregate's fields ; portals consume views by name
    /// (`record.view("for_customer")`) so role-scoped renderers all
    /// pull from the same single source of truth. Empty when no
    /// `view "name" do ... end` blocks were declared.
