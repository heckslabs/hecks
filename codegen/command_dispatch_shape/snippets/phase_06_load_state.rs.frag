    let (mut state, is_new) = if let Some(ref_name) = &self_ref {
        if let Some(id_val) = attrs.get(ref_name) {
            let id = id_val.to_string();
            match repo.find(&id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(id)),
            }
        } else if let Some(ref id) = cascade_id {
            // Cascade hint resolved a same-type id — reuse it even
            // when the command has a self-ref kwarg the cascade didn't
            // populate (the upstream event carries the id, not the
            // kwarg name).
            match repo.find(id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(id.clone())),
            }
        } else if is_create {
            (AggregateState::new(&repo.id_for_command(&attrs)), true)
        } else {
            return Err(RuntimeError::MissingAttribute("self-referencing id".into()));
        }
    } else if let Some(ref id) = cascade_id {
        // Same-type cascade with an existing record — reuse it,
        // skipping id_for_command's counter-mint.
        match repo.find(id).cloned() {
            Some(s) => (s, false),
            None => (AggregateState::new(id), true),
        }
    } else {
        let id = repo.id_for_command(&attrs);
        match repo.find(&id).cloned() {
            Some(s) => (s, false),
            None => (AggregateState::new(&id), true),
        }
    };
