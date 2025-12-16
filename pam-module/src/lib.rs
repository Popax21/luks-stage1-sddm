use std::{ffi::OsStr, os::unix::ffi::OsStrExt};

use nonstick::{ModuleClient, PamModule, items::ItemsMut, pam_export};
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
            return Err(nonstick::ErrorCode::Ignore);
        };

        let config = match ini::Ini::load_from_file(file) {
            Ok(c) => c,
            Err(err) => {
                nonstick::error!(
                    handle,
                    "error parsing transient initrd LUKS unlock SDDM config: {err:#}"
                );
                return Err(nonstick::ErrorCode::Ignore);
            }
        };

        let Some((user, pw_key)) = config.section(Some("Autologin")).and_then(|c| {
            c.get("User")
                .zip(c.get("PasswordKey").and_then(|k| k.parse().ok()))
        }) else {
            nonstick::error!(handle, "malformed transient initrd LUKS unlock SDDM config");
            return Err(nonstick::ErrorCode::Ignore);
        };

        //Check that the user is correct
        if handle.username(None)? != user {
            nonstick::debug!(
                handle,
                "ignoring SDDM auto login attempt for non-initrd login requestion {user:?}"
            );
            return Err(nonstick::ErrorCode::Ignore);
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
}
