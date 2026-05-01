    if i == 0 { return false; }
    let bytes = s.as_bytes();
    let mut count = 0;
    let mut j = i;
    while j > 0 && bytes[j - 1] == b'\\' {
        count += 1;
        j -= 1;
    }
    count % 2 == 1
