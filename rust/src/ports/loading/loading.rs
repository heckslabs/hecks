
use crate::adapters::driven::folder;
use std::path::Path;

pub fn declarations(directory: &Path, extension: &str) -> Vec<String> {
    bootstrap().read(directory, extension)
}

fn bootstrap() -> folder::Folder {
    folder::Folder
}
