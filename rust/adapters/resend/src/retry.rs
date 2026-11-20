//! How long to wait before trying again after a 429, and how a status is named.

/// Seconds waited when Resend's 429 carries no usable `retry-after`.
const DEFAULT_RETRY_SECS: u64 = 1;
/// The longest wait honoured, whatever `retry-after` asks.
const MAX_RETRY_SECS: u64 = 5;

/// The wait in milliseconds a 429 reply asks for, clamped to five seconds.
pub fn delay_ms(headers: &[(String, String)]) -> u32 {
    let secs = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("retry-after"))
        .and_then(|(_, value)| value.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_RETRY_SECS)
        .min(MAX_RETRY_SECS);
    u32::try_from(secs * 1000).unwrap_or(u32::MAX)
}

/// The status as the host's HTTP client names it (`403 Forbidden`), or the bare code.
pub fn status_line(status: u16) -> String {
    match reason(status) {
        Some(reason) => format!("{status} {reason}"),
        None => status.to_string(),
    }
}

fn reason(status: u16) -> Option<&'static str> {
    Some(match status {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => return None,
    })
}
