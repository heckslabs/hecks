    /// Commands declared inside the `entity "Foo" do … end` block.
    /// Dispatch addresses them as `Aggregate.Entity.Command` (3-part)
    /// or `Aggregate.Command` when the bare name is unique among the
    /// parent aggregate's entities (i111-J — close the DDD gap).
    /// Empty for entities declared with attributes only — backward
    /// compatible with pre-i111-J bluebooks.
