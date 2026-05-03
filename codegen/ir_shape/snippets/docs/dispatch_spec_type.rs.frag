/// One declarative `dispatch "Cmd", with: { ... }` entry. The
/// `with_spec` is an ordered list of `(attr_name, ValueSpec)` pairs ;
/// declaration order is preserved (canonical IR uses an ordered
/// list of pairs, not an unordered map). Empty `with_spec` means the
/// dispatch fires bare (runtime auto-injects upstream refs).
///
/// i221-A — `for_each` promotes a single dispatch to a sweep. When
/// `Some`, the runtime reads the named query at dispatch time and
/// fires the receiving command once per returned record ;
/// `from_iter(:field)` in the with-spec resolves against the current
/// iteration record. `None` is the back-compat default for every
/// existing dispatch.
