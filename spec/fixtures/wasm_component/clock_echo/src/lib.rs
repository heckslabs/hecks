//! A component that imports the host `clock` and exports `echo-time`, `spin` and `grow`.

wit_bindgen::generate!({
    path: "../../../../rust/host/wit",
    world: "clock-adapter-limits",
});

struct ClockEcho;

impl Guest for ClockEcho {
    fn echo_time() -> String {
        format!("t={}", hecks::adapters::clock::now_seconds())
    }

    fn spin() {
        let mut n: u64 = 0;
        loop {
            n = std::hint::black_box(n.wrapping_add(1));
        }
    }

    fn grow(pages: u32) -> u32 {
        let mut block = vec![0u8; pages as usize * 65_536];
        block[0] = 1;
        std::hint::black_box(&block);
        pages
    }
}

export!(ClockEcho);
