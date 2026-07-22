//! Shared integration-test fixture — boot a runtime against the REAL framework
//! substrate (adapters, families, event_sourcing, hexagon) with a caller-supplied
//! bluebook + hecksagon written into its own temp realm.
//!
//! The framework substrate matters : an in-process runtime booted from a bare
//! domain does NOT carry the Event Log, so a test that skips it proves nothing
//! about event sourcing. Each realm gets its own root so test binaries (and the
//! tests within one) never share a data dir.

use std::path::{Path, PathBuf};
use storehouse::runtime::Runtime;
use storehouse::{corpus_loader, embed};

pub fn conception() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("hecks_conception")
}

pub fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap_or_else(|e| panic!("read {:?}: {}", from, e)) {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_file() {
            std::fs::copy(entry.path(), to.join(entry.file_name())).unwrap();
        }
    }
}

/// Boot a realm at `root_name` carrying the framework substrate plus one domain
/// declared by `bluebook` + `hecksagon`, both written under `<domain>/bluebook`.
pub fn boot_realm(
    root_name: &str,
    domain: &str,
    bluebook: &str,
    hecksagon: &str,
) -> (Runtime, PathBuf) {
    let c = conception();
    let root = std::env::temp_dir().join(root_name);
    let _ = std::fs::remove_dir_all(&root);

    let fw = root.join("aggregates").join("framework");
    copy_dir(&c.join("aggregates/framework/adapters"), &fw.join("adapters"));
    copy_dir(&c.join("aggregates/framework/families"), &fw.join("families"));
    copy_dir(
        &c.join("aggregates/framework/event_sourcing/bluebook"),
        &fw.join("event_sourcing/bluebook"),
    );
    copy_dir(&c.join("aggregates/framework/hexagon/bluebook"), &fw.join("hexagon/bluebook"));

    let sd = fw.join(domain).join("bluebook");
    std::fs::create_dir_all(&sd).unwrap();
    std::fs::write(sd.join(format!("{domain}.bluebook")), bluebook).unwrap();
    std::fs::write(sd.join(format!("{domain}.hecksagon")), hecksagon).unwrap();

    let agg_dir = root.join("aggregates");
    let agg_dir_s = agg_dir.to_str().unwrap();
    let loaded = corpus_loader::load_combined_domain(agg_dir_s);
    let hecksagons = embed::load_hecksagons(agg_dir_s);
    let data = root.join("data").to_string_lossy().into_owned();
    let rt = Runtime::boot_with_framework_dir(loaded, Some(data), hecksagons, &agg_dir);
    (rt, root)
}
