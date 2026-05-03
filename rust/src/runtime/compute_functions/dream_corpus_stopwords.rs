//! [antibody-exempt: rust/src/runtime/compute_functions/dream_corpus_stopwords.rs —
//!  kernel-surface compute helper (i220 sub-gap 6, dream-corpus-tokenize).
//!  English + French stopword set extracted from
//!  miette/body/interpret_dream.sh's jq pipeline so
//!  tokenize_dream_corpus.rs stays under the file budget. Same
//!  retirement contract as the parent.]
//!
//! Stopword set for `tokenize_dream_corpus` — English + French,
//! mirror of the jq `stopwords` definition in
//! `miette/body/interpret_dream.sh` (lines 70-119). Kept as a flat
//! `&[&str]` so the membership test is a linear scan ; the per-call
//! corpus is small (one sleep window's images), so a HashSet
//! allocation is not worth it.
//!
//! When extending : also extend the shell's jq pipeline if the
//! shell still ships, so the windowed-tokenize parity stays
//! exact across both halves. Once the shell retires the registry
//! IS the source of truth.

pub const STOPWORDS: &[&str] = &[
    // English
    "the","a","an","and","or","of","to","in","is","it","that","this",
    "was","were","be","been","being","have","has","had","do","does","did",
    "will","would","should","could","i","my","me","you","your","she","he",
    "we","our","their","not","no","yes","so","but",
    "for","from","as","at","if","by","on","with","about","into","onto",
    "out","up","down","over","under","than","then","there","here","when",
    "where","how","why","what","who","which","whose","all","any","some",
    "just","only","still","now","too","very","can","may","might","must",
    "am","are","done","get","got","go","goes","went","gone",
    // French
    "le","la","les","un","une","des","du","de","au","aux",
    "je","tu","il","elle","nous","vous","ils","elles",
    "moi","toi","soi","lui","leur","y","en","ne","pas","plus","rien",
    "mon","ma","mes","ton","ta","tes","son","sa","ses","nos","vos",
    "que","qui","quoi","dont","comme","ou","mais","car","donc","ni",
    "par","pour","avec","sans","sur","sous","dans","chez","vers",
    "avant","apres","entre","pendant","depuis","contre",
    "est","sont","suis","es","sommes","etes","etait","etaient",
    "ai","as","avons","avez","ont","avais","avait","aurais","serait",
    "tout","toute","tous","toutes","meme","aussi","tres","bien","trop",
    "ce","cet","cette","ces","si","oui","non","dire","fait",
];

/// True when `candidate` is in the stopword set. Linear scan ; the
/// corpus per call is small enough that a HashSet wouldn't pay back
/// its allocation.
pub fn is_stopword(candidate: &str) -> bool {
    STOPWORDS.iter().any(|sw| *sw == candidate)
}
