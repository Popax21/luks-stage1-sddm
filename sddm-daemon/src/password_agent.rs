//! A simple [systemd password agent](https://systemd.io/PASSWORD_AGENTS/)

use std::{
    io::ErrorKind,
    os::{fd::AsFd, unix::net::UnixDatagram},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use inotify::{Inotify, WatchMask};
use smol::{
    Async,
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

            //Check if the file still exists
            if !path.exists() {
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

    pub fn reply(self, password: Option<Zeroizing<Box<str>>>) -> Result<()> {
        let socket = UnixDatagram::unbound().context("failed to open client socket")?;

        match socket.connect(&self.socket_path) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                //Someone else already replied to the request first
                println!(
                    "attempted to reply to stale password request for {:?}",
                    self.id.as_deref().unwrap_or("<unknown>")
                );
                return Ok(());
            }
            Err(err) => return Err(err).context("failed to connect to password request socket"),
        }

        if let Some(password) = password {
            socket.send(format!("+{}", *password).as_bytes())
        } else {
            socket.send(b"-")
        }
        .context("failed to send password reply to password request socket")?;

        Ok(())
    }
}
