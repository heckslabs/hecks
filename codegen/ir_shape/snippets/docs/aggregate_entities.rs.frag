    /// Non-root entities owned by this aggregate. They have identity
    /// within the aggregate (some natural key field) and can mutate
    /// over their lifecycle, but are reached only through the root —
    /// other aggregates `reference_to` the root, never directly to
    /// the entity. Lifecycle bounded by the parent : when the
    /// aggregate's record is deleted the entities go with it.
    /// Distinct from `value_objects` (no identity, immutable, replaced
    /// wholesale) and from a separate `Aggregate` (queryable by id
    /// from outside, lifecycle independent).
