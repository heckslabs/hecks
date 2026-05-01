
    if command == "terminal" {
        let dir = if !path.is_empty() {
            path.to_string()
        } else {
            resolve_home(&being)
        };
        run_terminal(&dir, &being);
        return;
    }
