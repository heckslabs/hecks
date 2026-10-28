//! Ruby-style `Float#to_s` and the finite-result check shared by float arithmetic.
//!
//! Fault wording quotes operands the way Ruby prints them (`1.0e+308`, not Rust's 309-digit
//! expansion), so a Fault from either runtime reads the same.

use crate::Refusal;

// Ruby switches to scientific notation when the decimal point sits left of 1e-4 or right of 1e16.
const FIXED_MIN_EXPONENT: i32 = -4;
const FIXED_MAX_EXPONENT: i32 = 15;

/// `Float#to_s`: shortest round-trip digits, fixed notation for `1e-4 <= |n| < 1e16`, else `d.ddde+XX`.
pub fn to_s(n: f64) -> String {
    if n.is_nan() {
        return "NaN".to_string();
    }
    if n.is_infinite() {
        return if n < 0.0 { "-Infinity" } else { "Infinity" }.to_string();
    }
    let sign = if n.is_sign_negative() { "-" } else { "" };
    if n == 0.0 {
        return format!("{sign}0.0");
    }
    // `{:e}` yields the shortest round-trip digits as `d.ddde<exp>`.
    let scientific = format!("{:e}", n.abs());
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    if (FIXED_MIN_EXPONENT..=FIXED_MAX_EXPONENT).contains(&exponent) {
        return format!("{sign}{}", fixed(&digits, exponent));
    }
    let (head, tail) = digits.split_at(1);
    let tail = if tail.is_empty() { "0" } else { tail };
    let exponent_sign = if exponent < 0 { '-' } else { '+' };
    format!("{sign}{head}.{tail}e{exponent_sign}{:02}", exponent.abs())
}

// Places the decimal point `exponent` digits after the first digit, padding zeros as needed.
fn fixed(digits: &str, exponent: i32) -> String {
    if exponent < 0 {
        let zeros = "0".repeat(exponent.unsigned_abs() as usize - 1);
        return format!("0.{zeros}{digits}");
    }
    let whole_len = exponent as usize + 1;
    if digits.len() <= whole_len {
        let zeros = "0".repeat(whole_len - digits.len());
        return format!("{digits}{zeros}.0");
    }
    let (whole, fraction) = digits.split_at(whole_len);
    format!("{whole}.{fraction}")
}

/// Passes a float arithmetic `result` through only if finite; else the C3.4 Fault.
///
/// Ruby quotes the right operand by absolute value, so a decrement still reads `a - |b|`.
pub fn finite_or_fault(
    op: &str,
    symbol: &str,
    lhs: f64,
    rhs: f64,
    result: f64,
) -> Result<f64, Refusal> {
    if result.is_finite() {
        return Ok(result);
    }
    Err(Refusal::Fault(format!(
        "{op} overflowed: {} {symbol} {} is not a finite number",
        to_s(lhs),
        to_s(rhs.abs())
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_numbers_keep_a_decimal_point() {
        assert_eq!(to_s(1.0), "1.0");
        assert_eq!(to_s(-250.0), "-250.0");
        assert_eq!(to_s(0.0), "0.0");
    }

    #[test]
    fn fractions_print_shortest_round_trip_digits() {
        assert_eq!(to_s(0.1), "0.1");
        assert_eq!(to_s(1.5), "1.5");
        assert_eq!(to_s(0.0001), "0.0001");
        assert_eq!(to_s(123_456.789), "123456.789");
    }

    #[test]
    fn large_magnitudes_switch_to_scientific_at_1e16() {
        assert_eq!(to_s(1.0e15), "1000000000000000.0");
        assert_eq!(to_s(1.0e16), "1.0e+16");
        assert_eq!(to_s(1.0e308), "1.0e+308");
        assert_eq!(to_s(1.5e20), "1.5e+20");
    }

    #[test]
    fn small_magnitudes_switch_to_scientific_below_1e_4() {
        assert_eq!(to_s(0.00001), "1.0e-05");
        assert_eq!(to_s(1.25e-7), "1.25e-07");
    }

    #[test]
    fn non_finite_values_use_rubys_names() {
        assert_eq!(to_s(f64::INFINITY), "Infinity");
        assert_eq!(to_s(f64::NEG_INFINITY), "-Infinity");
        assert_eq!(to_s(f64::NAN), "NaN");
    }

    #[test]
    fn an_infinite_result_faults_with_rubys_wording() {
        let fault = finite_or_fault("increment", "+", 1.0e308, 1.0e308, f64::INFINITY);
        assert_eq!(
            fault,
            Err(Refusal::Fault(
                "increment overflowed: 1.0e+308 + 1.0e+308 is not a finite number".to_string()
            ))
        );
    }

    #[test]
    fn a_decrement_quotes_the_amount_by_absolute_value() {
        let fault = finite_or_fault("decrement", "-", -1.0e308, -1.0e308, f64::NEG_INFINITY);
        assert_eq!(
            fault,
            Err(Refusal::Fault(
                "decrement overflowed: -1.0e+308 - 1.0e+308 is not a finite number".to_string()
            ))
        );
    }

    #[test]
    fn a_finite_result_passes_through() {
        assert_eq!(finite_or_fault("multiply", "*", 2.0, 3.0, 6.0), Ok(6.0));
    }
}
