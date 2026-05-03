/// One declarative `dispatch "Cmd", with: { ... }` entry. The
/// `with_spec` is an ordered list of `(attr_name, ValueSpec)` pairs ;
/// declaration order is preserved (canonical IR uses an ordered
/// list of pairs, not an unordered map). Empty `with_spec` means the
/// dispatch fires bare (runtime auto-injects upstream refs).
