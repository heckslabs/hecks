//! loading - the port's execution : a directory in, declarations out.
//!
//! The twin of lib/hecksagain/ports/loading/loading.rb. Everything this side
//! does to a disk to find a domain's declarations - reading a directory,
//! filtering by extension, reading each file - belongs here rather than being
//! spread through whoever happened to need it.
//!
//! THE BOOTSTRAP, same as Ruby's. This port cannot resolve itself by lookup :
//! resolving a port means reading the file that declares it, and reading files
//! is the thing this port does. So `bootstrap` names the one adapter that must
//! be known before anything else can be, and reaches for it directly. It is the
//! only place in the projection an adapter is named by path rather than
//! resolved. The circularity is real ; what it can be is small and named.
//!
//! ASYMMETRY WORTH KEEPING. Ruby has a third port, EXTRACTION, and this side has
//! none - deliberately, not as an omission. Ruby must recover a predicate's
//! source from a Proc that has already swallowed it, so it re-reads the file
//! with Prism ; that is a genuine impure edge and it is declared. The projection
//! never loses the text : it reads the .bluebook as text and the expression is
//! simply there. An edge that does not exist should not be declared just to make
//! two trees look alike.

use crate::adapters::driven::folder;
use std::path::Path;

/// Every declaration of one kind sitting beside a domain, in sorted order.
///
/// Sorted because two runtimes reading the same directory in different orders
/// would resolve the same domain differently, and "they agree" would mean
/// nothing.
pub fn declarations(directory: &Path, extension: &str) -> Vec<String> {
    bootstrap().read(directory, extension)
}

/// The single hardcoded edge. See THE BOOTSTRAP above.
fn bootstrap() -> folder::Folder {
    folder::Folder
}
