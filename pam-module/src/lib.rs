use std::{ffi::OsStr, os::unix::ffi::OsStrExt};

use nonstick::{ConversationAdapter, ModuleClient, PamModule, items::ItemsMut, pam_export};
use zeroize::Zeroizing;

struct SddmInitrdAutologin;
pam_export!(SddmInitrdAutologin);

impl<M: ModuleClient> PamModule<M> for SddmInitrdAutologin {
    fn authenticate(
        handle: &mut M,
        _args: Vec<&std::ffi::CStr>,
        _flags: nonstick::AuthnFlags,
    ) -> nonstick::Result<()> {
        //Read the transient SDDM config file written by the daemon
        let Some(file) = std::option_env!("TRANSIENT_SDDM_CONF") else {
            return Err(nonstick::ErrorCode::UserUnknown);
        };

        if !std::fs::exists(file).unwrap_or(false) {
            return Err(nonstick::ErrorCode::UserUnknown);
        }

        let config = match ini::Ini::load_from_file(file) {
            Ok(c) => c,
            Err(err) => {
                nonstick::error!(
                    handle,
                    "error parsing transient initrd LUKS unlock SDDM config: {err:#}"
                );
                return Err(nonstick::ErrorCode::UserUnknown);
            }
        };

        let Some((user, pw_key)) = config.section(Some("Autologin")).and_then(|c| {
            c.get("User")
                .zip(c.get("PasswordKey").and_then(|k| k.parse().ok()))
        }) else {
            nonstick::error!(handle, "malformed transient initrd LUKS unlock SDDM config");
            return Err(nonstick::ErrorCode::UserUnknown);
        };

        //Check that the user is correct
        if handle.username(None)? != user {
            nonstick::debug!(
                handle,
                "ignoring SDDM auto login attempt for non-initrd login requestion {user:?}"
            );
            return Err(nonstick::ErrorCode::UserUnknown);
        }

        //Delete the transient SDDM config file; no matter if we succeed, we only give this one attempt
        if let Err(err) = std::fs::remove_file(file) {
            nonstick::debug!(
                handle,
                "error deleting transient initrd LUKS unlock SDDM config: {err:#}"
            );
            return Err(nonstick::ErrorCode::SystemError);
        }

        //Load the password from the keyring
        let pw_key = linux_keyutils::Key::from_id(linux_keyutils::KeySerialId(pw_key));

        let mut pw = Zeroizing::new(vec![0u8; 0x1000]);
        match pw_key.read(&mut pw) {
            Ok(sz) => pw.truncate(sz),
            Err(err) => {
                nonstick::error!(
                    handle,
                    "failed to read initrd LUKS unlock password keyring key: {err:#}"
                );
                return Err(nonstick::ErrorCode::SystemError);
            }
        }

        if let Err(err) = pw_key.revoke() {
            nonstick::debug!(
                handle,
                "error revoking initrd LUKS unlock password keyring key: {err:#}"
            );
            return Err(nonstick::ErrorCode::SystemError);
        }

        //Plug the password back into PAM
        if let Err(err) = {
            let mut items = handle.items_mut();
            items.set_authtok(Some(OsStr::from_bytes(&pw)))
        } {
            nonstick::error!(
                handle,
                "failed to set authtok from initrd LUKS unlock password: {err:#}"
            );
            return Err(nonstick::ErrorCode::AuthTokError);
        }

        nonstick::info!(
            handle,
            "handing off initrd LUKS unlock login request for user {user:?}"
        );

        Ok(())
    }

    fn change_authtok(
        handle: &mut M,
        args: Vec<&std::ffi::CStr>,
        action: nonstick::AuthtokAction,
        flags: nonstick::AuthtokFlags,
    ) -> nonstick::Result<()> {
        if action != nonstick::AuthtokAction::Update
            || flags.contains(nonstick::AuthtokFlags::CHANGE_EXPIRED_AUTHTOK)
        {
            return Ok(());
        }

        let user = handle.username(None)?;
        let old_authtok = handle.old_authtok(None)?;
        let new_authtok = handle.authtok(None)?;

        //Check that this is a user whose password we are managing
        'user_ok: {
            for &arg in &args {
                let arg = arg.to_str().map_err(|_| nonstick::ErrorCode::BufferError)?;
                if arg.strip_prefix("user=").is_some_and(|u| u == user) {
                    break 'user_ok;
                }
            }
            return Ok(());
        };

        //Find the cryptsetup binary
        let mut cryptsetup = "cryptsetup";
        for &arg in &args {
            let arg = arg.to_str().map_err(|_| nonstick::ErrorCode::BufferError)?;
            if let Some(exe) = arg.strip_prefix("cryptsetup=") {
                cryptsetup = exe;
            }
        }

        //Change LUKS keys of all devices
        for &arg in &args {
            let arg = arg.to_str().map_err(|_| nonstick::ErrorCode::BufferError)?;
            let Some(device) = arg.strip_prefix("luksDevice=") else {
                continue;
            };

            use std::io::Write;

            let (reader, mut writer) = std::io::pipe().unwrap();
            writer.write_all(old_authtok.as_encoded_bytes()).unwrap();
            writer.write_all(b"\n").unwrap();
            writer.write_all(new_authtok.as_encoded_bytes()).unwrap();
            writer.write_all(b"\n").unwrap();

            handle.info_msg(format!("Changing LUKS password of {device:?}"));

            let desync_warning = || {
                handle.error_msg("Failed to change LUKS password (check syslog) - the LUKS and user passwords might have desynced!")
            };

            match std::process::Command::new(cryptsetup)
                .arg("luksChangeKey")
                .arg(device)
                .stdin(reader)
                .status()
            {
                Ok(status) if status.success() => {
                    nonstick::info!(handle, "changed LUKS password of {device:?}");
                }
                Ok(status) => {
                    nonstick::error!(
                        handle,
                        "failed to change LUKS password for {device:?}: cryptsetup exited with {status}"
                    );
                    desync_warning();
                }
                Err(err) => {
                    nonstick::error!(
                        handle,
                        "failed to change LUKS password for {device:?}: {err}"
                    );
                    desync_warning();
                }
            }
        }

        Ok(())
    }
}
