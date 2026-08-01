//! The held era texts for one domain — twin of
//! lib/hecksagain/ports/persistence/era_store.rb, minus minting: era
//! names are minted once, by the Ruby scaffold, and this side only ever
//! READS stored names. Each era's bluebook source is written once, at
//! the first boot of that era, and frozen forever. File adapters share
//! the store under `<root>/data/eras/<domain>/`; Postgres keeps the
//! same facts in its `hecks_eras` table instead.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

/// The verdict wordings are byte-identical with Ruby's
/// `Ports::Persistence::EraTamper` — when an integrity digest fails,
/// EITHER runtime can say whether the edit changed what the era meant
/// (structural projection comparison, the mechanism every boot already
/// trusts) or only its words. No hashing, no canonical serialization:
/// a Rust-only deployment learns which situation it is in at 3am, even
/// though the repair tool itself is Ruby.
fn tamper_refusal(domain: &str, ordinal: u32, edited_text: &str, stored_projection: Option<&Value>) -> String {
    let base = format!("cannot boot {domain}: the held text of era {ordinal} was edited after it was frozen");
    if let Some(stored) = stored_projection {
        let edited = crate::runtime::storage_shape::project(&crate::bluebook::parser::parse(edited_text));
        if edited == *stored {
            return format!(
                "{base} — the edit is cosmetic to the storage shape; \
                 re-attest it (bin/reattest_era), or restore the original text from the era archive"
            );
        }
        return format!(
            "{base} AND the edit changed the storage shape — \
             re-attestation will refuse it; restore the original text from the era archive"
        );
    }
    format!("{base} — held era texts are storage facts; restore the original text, or reset the data")
}

pub struct EraStore {
    pub dir: PathBuf,
    domain: String,
}

const NAMES: &str = "names.tsv";
const INTEGRITY: &str = "integrity.tsv";

impl EraStore {
    pub fn new(root: &Path, domain_name: &str) -> Self {
        EraStore {
            dir: root.join("data").join("eras").join(crate::naming::snake(domain_name)),
            domain: domain_name.to_string(),
        }
    }

    /// [(ordinal, source text), ...] sorted by ordinal — every era this
    /// store has ever held, era 1 first. Each text is verified against
    /// its INTEGRITY digest on the way out: the era name is minted from
    /// the projection and never recomputed, but the held BYTES are a
    /// storage fact, and an edited storage fact must refuse — silently
    /// reporting "no drift" over doctored text is exactly the disease
    /// this whole machinery exists to cure. A missing digest (a store
    /// from before this check) is backfilled, not refused.
    pub fn held_texts(&self) -> Result<Vec<(u32, String)>, String> {
        if !self.dir.is_dir() {
            return Ok(vec![]);
        }
        let mut ordinals: Vec<(u32, PathBuf)> = fs::read_dir(&self.dir)
            .map_err(|error| format!("cannot read {}: {error}", self.dir.display()))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "bluebook"))
            .filter_map(|path| {
                let stem = path.file_stem()?.to_str()?.parse::<u32>().ok()?;
                (stem > 0).then_some((stem, path))
            })
            .collect();
        ordinals.sort_by_key(|(ordinal, _)| *ordinal);
        ordinals
            .into_iter()
            .map(|(ordinal, path)| {
                let text = fs::read_to_string(&path)
                    .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
                self.verify_integrity(ordinal, &text)?;
                Ok((ordinal, text))
            })
            .collect()
    }

    pub fn held_path(&self, ordinal: u32) -> PathBuf {
        self.dir.join(format!("{ordinal}.bluebook"))
    }

    pub fn hold_first(&self, text: &str, projection: Option<&Value>) -> Result<(), String> {
        fs::create_dir_all(&self.dir).map_err(|error| format!("cannot create {}: {error}", self.dir.display()))?;
        let path = self.held_path(1);
        if path.exists() {
            return Err(format!(
                "era 1 of {} is already held — held texts are frozen forever",
                self.dir.file_name().and_then(|name| name.to_str()).unwrap_or_default()
            ));
        }
        fs::write(&path, text).map_err(|error| format!("cannot write {}: {error}", path.display()))?;
        self.record_integrity(1, text)?;
        if let Some(projection) = projection {
            self.record_projection(1, projection)?;
        }
        self.archive(1, text)
    }

    fn projection_path(&self, ordinal: u32) -> PathBuf {
        self.dir.join(format!("{ordinal}.projection.json"))
    }

    fn stored_projection(&self, ordinal: u32) -> Option<Value> {
        let text = fs::read_to_string(self.projection_path(ordinal)).ok()?;
        serde_json::from_str(&text).ok()
    }

    fn record_projection(&self, ordinal: u32, projection: &Value) -> Result<(), String> {
        let path = self.projection_path(ordinal);
        if path.exists() {
            return Ok(());
        }
        fs::write(&path, serde_json::to_string(projection).unwrap_or_default())
            .map_err(|error| format!("cannot write {}: {error}", path.display()))
    }

    /// Every frozen text version, archived where an edit cannot reach
    /// it — the recovery the hard reattest refusal points at.
    fn archive(&self, ordinal: u32, text: &str) -> Result<(), String> {
        let archive_dir = self.dir.join("archive");
        fs::create_dir_all(&archive_dir).map_err(|error| format!("cannot create {}: {error}", archive_dir.display()))?;
        let digest = crate::util::sha256_hex(text.as_bytes());
        let path = archive_dir.join(format!("{ordinal}-{}.bluebook", &digest[..12]));
        if path.exists() {
            return Ok(());
        }
        fs::write(&path, text).map_err(|error| format!("cannot write {}: {error}", path.display()))
    }

    fn integrity_digests(&self) -> Vec<(u32, String)> {
        let Ok(lines) = fs::read_to_string(self.dir.join(INTEGRITY)) else {
            return vec![];
        };
        lines
            .lines()
            .filter(|line| !line.is_empty())
            .filter_map(|line| {
                let mut fields = line.split('\t');
                let ordinal: u32 = fields.next()?.parse().ok()?;
                let digest = fields.next()?.to_string();
                Some((ordinal, digest))
            })
            .collect()
    }

    fn record_integrity(&self, ordinal: u32, text: &str) -> Result<(), String> {
        if self.integrity_digests().iter().any(|(stored, _)| *stored == ordinal) {
            return Ok(());
        }
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join(INTEGRITY))
            .map_err(|error| format!("cannot write {}: {error}", self.dir.join(INTEGRITY).display()))?;
        writeln!(file, "{ordinal}\t{}", crate::util::sha256_hex(text.as_bytes()))
            .map_err(|error| format!("cannot write {}: {error}", self.dir.join(INTEGRITY).display()))
    }

    fn verify_integrity(&self, ordinal: u32, text: &str) -> Result<(), String> {
        // LAST entry wins, matching Ruby's Hash-building semantics — a
        // re-attested store must read identically from both runtimes.
        let stored = self.integrity_digests().into_iter().filter(|(o, _)| *o == ordinal).next_back().map(|(_, d)| d);
        let Some(stored) = stored else {
            self.record_integrity(ordinal, text)?;
            return self.backfill_frozen_facts(ordinal, text);
        };
        if stored == crate::util::sha256_hex(text.as_bytes()) {
            return self.backfill_frozen_facts(ordinal, text);
        }
        Err(tamper_refusal(&self.domain, ordinal, text, self.stored_projection(ordinal).as_ref()))
    }

    /// A verified-authentic text backfills what older stores lack: its
    /// projection and its archive copy. Never run on a text that failed
    /// verification — that would bless the edit.
    fn backfill_frozen_facts(&self, ordinal: u32, text: &str) -> Result<(), String> {
        self.archive(ordinal, text)?;
        if self.projection_path(ordinal).exists() {
            return Ok(());
        }
        let projection = crate::runtime::storage_shape::project(&crate::bluebook::parser::parse(text));
        self.record_projection(ordinal, &projection)
    }

    /// A stored era name's short label, if the Ruby scaffold has minted
    /// one — never computed here.
    pub fn label_for(&self, ordinal: u32) -> Option<String> {
        let names = fs::read_to_string(self.dir.join(NAMES)).ok()?;
        names.lines().filter(|line| !line.is_empty()).find_map(|line| {
            let mut fields = line.split('\t');
            let stored: u32 = fields.next()?.parse().ok()?;
            let _hash = fields.next()?;
            let label = fields.next()?;
            (stored == ordinal).then(|| label.to_string())
        })
    }
}
