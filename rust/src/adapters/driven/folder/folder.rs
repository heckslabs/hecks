use std::fs;
use std::path::{Path, PathBuf};

pub struct Folder;

impl Folder {
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
