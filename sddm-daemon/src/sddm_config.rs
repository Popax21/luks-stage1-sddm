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

    //Save the password into the user / root keyring
    use linux_keyutils::{KeyPermissionsBuilder, KeyRing, KeyRingIdentifier, Permission};

    let pw_key = KeyRing::from_special_id(KeyRingIdentifier::Process, true)
        .expect("failed to open process keyring")
        .add_key("luks-initrd-sddm-unlock-pw", request.password.as_bytes())
        .expect("failed to add password to login root keyring");

    let perms = KeyPermissionsBuilder::builder()
        .posessor(Permission::ALL)
        .user(Permission::VIEW | Permission::READ | Permission::SETATTR)
        .build();

    pw_key
        .set_perms(perms)
        .expect("failed to set password key perms");

    pw_key
        .set_timeout(60)
        .expect("failed to set password key timeout");

    KeyRing::from_special_id(KeyRingIdentifier::User, true)
        .expect("failed to open root keyring")
        .link_key(pw_key)
        .expect("failed to link password key into root keyring");

    //Write the config file
    let session = request
        .session
        .file_name()
        .and_then(|s| s.to_str())
        .context("malformed login session")?;

    let mut file = std::fs::File::create_new(file)?;
    writeln!(file, "[Autologin]")?;
    writeln!(file, "User={}", request.user)?;
    writeln!(file, "PasswordKey={}", pw_key.get_id().0)?;
    writeln!(file, "Session={session}")?;

    Ok(())
}
