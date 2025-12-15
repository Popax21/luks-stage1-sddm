use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::login_controller::LoginRequest;

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
                    eprintln!(
                        "a SDDM theme was specified but the ThemeDir property was not set; ignoring..."
                    );
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

pub fn write_transient_sddm_config(request: &LoginRequest) -> Result<()> {
    use std::io::Write;

    let Some(file) = std::option_env!("TRANSIENT_SDDM_CONF") else {
        return Ok(());
    };

    let session = request
        .session
        .file_name()
        .and_then(|s| s.to_str())
        .context("malformed login session")?;

    let mut file = std::fs::File::create_new(file)?;
    writeln!(file, "[Autologin]")?;
    writeln!(file, "User={}", request.user)?;
    writeln!(file, "Session={session}",)?;

    Ok(())
}
