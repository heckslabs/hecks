    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{}", self.name)?;
        let agg_count = self.aggregates.len();
        for (ai, agg) in self.aggregates.iter().enumerate() {
            let is_last_agg = ai == agg_count - 1;
            let prefix = if is_last_agg { "└──" } else { "├──" };
            let cont = if is_last_agg { "    " } else { "│   " };
            writeln!(f, "{} {} — {}", prefix, agg.name, agg.description.as_deref().unwrap_or(""))?;
            let cmd_count = agg.commands.len();
            for (ci, cmd) in agg.commands.iter().enumerate() {
                let cmd_prefix = if ci == cmd_count - 1 { "└──" } else { "├──" };
                write!(f, "{}{} {}", cont, cmd_prefix, cmd.name)?;
                if let Some(ref emits) = cmd.emits {
                    write!(f, " -> {}", emits)?;
                }
                writeln!(f)?;
            }
        }
        if !self.policies.is_empty() {
            for pol in &self.policies {
                writeln!(f, "  {} : {} -> {}", pol.name, pol.on_event, pol.trigger_command)?;
            }
        }
        Ok(())
    }
