use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

pub struct SddmConfig {
    pub theme: Option<PathBuf>,
    pub luks_devices: Vec<PathBuf>,
}

impl SddmConfig {
    pub fn load_from_file(path: &Path) -> Result<SddmConfig> {
        let ini = ini::Ini::load_from_file(path)?;

        let theme = if let Some(sec) = ini.section(Some("Theme")) {
            if let Some(theme) = sec.get("Current").filter(|t| !t.is_empty()) {
                if let Some(dir) = sec.get("ThemeDir") {
                    Some(Path::new(dir).join(theme))
                } else {
                    eprintln!("a SDDM theme was specified but the ThemeDir property was not set; ignoring...");
                    None
                }
            } else {
                None
            }
        } else {
            None
        };

        let luks_devices = ini
            .section(Some("LUKSUnlock"))
            .context("no LUKSUnlock section")?
            .get_all("Devices")
            .map(PathBuf::from)
            .collect();

        Ok(SddmConfig {
            theme,
            luks_devices,
        })
    }
}
