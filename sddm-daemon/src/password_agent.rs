//! A simple [systemd password agent](https://systemd.io/PASSWORD_AGENTS/)

use std::{
    io::ErrorKind,
    os::fd::AsFd,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, ensure};
use inotify::{Inotify, WatchMask};
use smol::{
    Async,
    io::AsyncWriteExt,
    process::{Command, Stdio},
    stream::{Stream, StreamExt},
};
use zeroize::Zeroizing;

#[derive(Debug, Hash)]
pub struct PasswordRequest {
    socket_path: PathBuf,
    pub id: Option<String>,
    pub message: Option<String>,
}

impl PasswordRequest {
    pub fn listen() -> Result<impl Stream<Item = PasswordRequest>> {
        const REQUESTS_DIR: &str = "/run/systemd/ask-password/";

        //Configure an inotify listener for the password request directory
        let notify = Inotify::init().context("failed to init inotify")?;
        notify
            .watches()
            .add(REQUESTS_DIR, WatchMask::CLOSE_WRITE | WatchMask::MOVED_TO)
            .context("failed to add inotify watcher")?;

        // - wrap the inotify code in an async stream for easier consumption
        let source = Async::new(notify.as_fd().try_clone_to_owned()?)
            .context("failed to make inotify async")?;

        let events = smol::stream::unfold((source, notify), async move |(source, mut notify)| {
            let events = source
                .read_with(|_| {
                    let mut buffer = [0u8; 4096];

                    let events: Vec<_> = notify
                        .read_events(&mut buffer)?
                        .filter_map(|ev| ev.name)
                        .map(|n| Path::new(REQUESTS_DIR).join(n))
                        .collect();

                    if !events.is_empty() {
                        Ok(smol::stream::iter(events))
                    } else {
                        Err(ErrorKind::WouldBlock.into())
                    }
                })
                .await
                .expect("failed to read inotify events");

            Some((events, (source, notify)))
        })
        .flatten();

        //Handle any events that come in
        Ok(events.filter_map(|path| {
            //We only care about files which start with `ask.XXXXXXX`
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_none_or(|n| !n.starts_with("ask."))
            {
                return None;
            }

            //Try to load the request from the INI file
            match Self::load_from_ini(&path) {
                Ok(req) => Some(req),
                Err(err) => {
                    eprintln!("failed to load password request from ini file {path:?}: {err:#}");
                    None
                }
            }
        }))
    }

    fn load_from_ini(path: &Path) -> Result<PasswordRequest> {
        let ini = ini::Ini::load_from_file(path)?;

        let ask_section = ini.section(Some("Ask")).context("no Ask section")?;
        let socket = ask_section.get("Socket").context("no Socket property")?;
        let id = ask_section.get("Id");
        let message = ask_section.get("Message");

        Ok(PasswordRequest {
            id: id.map(String::from),
            message: message.map(String::from),
            socket_path: PathBuf::from(socket),
        })
    }

    pub async fn reply(self, password: Option<Zeroizing<Box<str>>>) -> Result<()> {
        //Don't write into the socket directly; instead run
        //systemd-reply-password
        // - we don't use pkexec since it's not present in the initrd, but
        //   we still don't write into the socket ourselves since the reply
        //   program might be a wrapper with setuid permissions
        let mut child =
            Command::new(option_env!("EXE_REPLY_PASSWORD").unwrap_or("systemd-reply-password"))
                .arg(if password.is_some() { "1" } else { "0" })
                .arg(self.socket_path)
                .stdin(Stdio::piped())
                .spawn()
                .context("failed to run systemd-reply-password")?;

        if let Some(password) = password {
            child
                .stdin
                .as_mut()
                .unwrap()
                .write_all(password.as_bytes())
                .await
                .context("failed to write password to stdin")?;
        };

        let status = child.status().await?;
        ensure!(
            status.success(),
            "systemd-reply-password exited with status {status}"
        );

        Ok(())
    }
}
