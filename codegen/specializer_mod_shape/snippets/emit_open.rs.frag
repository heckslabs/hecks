
/// Dispatch by target name. Each Rust-native specializer has one
/// match arm here and one sibling module.
pub fn emit(target: &str, repo_root: &Path) -> Result<String, Box<dyn Error>> {
    match target {
