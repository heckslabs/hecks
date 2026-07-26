//! Folder - the loading adapter that reads declarations off a disk.
//!
//! The twin of lib/hecksagain/adapters/driven/folder/folder.rb. It implements ONE
//! convention : a domain's declarations are the files sitting beside its
//! .bluebook, and they are read in sorted order.
//!
//! Naming it as an adapter is what makes it a convention rather than a law. A
//! different loading adapter - a manifest, an embedded set of declarations
//! compiled into the binary, a database of domains - is additive against the
//! loading port and needs no change to anything that consumes it.
//!
//! It is DRIVEN : something asks it for declarations and it answers. The
//! filesystem never reaches in and starts anything.

use std::fs;
use std::path::{Path, PathBuf};

pub struct Folder;

impl Folder {
    /// Every file of one extension in a directory, sorted, read to string.
    ///
    /// A directory that cannot be read yields nothing rather than failing : a
    /// domain with no .world is the ordinary case, not an error.
    pub fn read(&self, directory: &Path, extension: &str) -> Vec<String> {
        let mut found = vec![];

        let Ok(entries) = fs::read_dir(directory) else {
            return found;
        };

        let mut paths: Vec<PathBuf> = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|e| e.to_str()) == Some(extension))
            .collect();
        paths.sort();

        for path in paths {
            if let Ok(source) = fs::read_to_string(&path) {
                found.push(source);
            }
        }
        found
    }
}
