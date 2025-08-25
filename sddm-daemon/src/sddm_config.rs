use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

pub struct SddmConfig {
    pub theme: Option<PathBuf>,
}

impl SddmConfig {
    pub fn load_from_file(path: &Path) -> Result<SddmConfig> {
        let ini = ini::Ini::load_from_file(path)?;

        let theme = if let Some(sec) = ini.section(Some("Theme")) {
            if let Some(theme) = sec.get("Current") {
                let dir = sec.get("ThemeDir").context("no ThemeDir property")?;
                Some(Path::new(dir).join(theme))
            } else {
                None
            }
        } else {
            None
        };

        Ok(SddmConfig { theme })
    }
}
