/// Call the local `claude` binary with `-p <input>` and capture stdout.
/// No prompt wrapper — the input is the full prompt, verbatim. Used
/// for free-form generation (dream production, translation) where the
/// bluebook owns the prompt text.
///
/// Timeout: 20s. Output is trimmed ; blank / too-short responses are
/// treated as failure so the caller can fall back gracefully.
