use std::{
    io::{Error, ErrorKind, Result},
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    sync::LazyLock,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const EFIVARFS_DIR: &str = "/sys/firmware/efi/efivars";

const HANDOFF_VAR_NAME: &str = "LuksStage1HibernationHandoff-c88791b4-89a7-47bc-b917-2db8dde158f8";
const HANDOFF_VAR_ATTRS: u32 = 0x00000001 | 0x00000002 | 0x00000004; // EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS

static HANDOFF_VAR_PATH: LazyLock<PathBuf> =
    LazyLock::new(|| PathBuf::from(EFIVARFS_DIR).join(HANDOFF_VAR_NAME));

#[derive(Debug, Clone)]
pub struct Handoff {
    pub timestamp: SystemTime,
    pub user: String,
}

impl Handoff {
    pub fn new(user: String) -> Self {
        Handoff {
            timestamp: SystemTime::now(),
            user,
        }
    }

    pub fn is_fresh(&self) -> bool {
        let now = SystemTime::now();
        let fresh_range = now - Duration::from_secs(30)..now + Duration::from_secs(5);
        fresh_range.contains(&self.timestamp)
    }
}

fn has_efivarfs() -> Result<bool> {
    //Ensure efivarfs is mounted & non-empty
    match std::fs::read_dir(EFIVARFS_DIR) {
        Ok(mut dir) => dir.next().map_or(Ok(false), |res| res.map(|_| true)),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(false),
        Err(err) => Err(err),
    }
}

fn clear_immutable_flag(path: &Path) -> Result<()> {
    nix::ioctl_read!(fs_ioc_getflags, b'f', 1, nix::libc::c_int);
    nix::ioctl_write_ptr!(fs_ioc_setflags, b'f', 2, nix::libc::c_int);

    const FS_IMMUTABLE_FL: nix::libc::c_int = 0x10;

    //Clear the immutable flag from the file (if set)
    let file = std::fs::File::open(path)?;

    let mut flags: nix::libc::c_int = 0;
    unsafe { fs_ioc_getflags(file.as_raw_fd(), &mut flags) }?;

    if flags & FS_IMMUTABLE_FL != 0 {
        flags &= !FS_IMMUTABLE_FL;
        unsafe { fs_ioc_setflags(file.as_raw_fd(), &flags) }?;
    }

    Ok(())
}

pub fn store(handoff: &Handoff) -> Result<()> {
    if !has_efivarfs()? {
        return Err(Error::new(
            ErrorKind::Unsupported,
            "system doesn't have efivarfs mounted",
        ));
    }

    let timestamp = handoff
        .timestamp
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let mut buf = Vec::new();
    buf.extend_from_slice(&HANDOFF_VAR_ATTRS.to_le_bytes());
    buf.extend_from_slice(&timestamp.to_le_bytes());
    buf.extend_from_slice(handoff.user.as_bytes());

    if HANDOFF_VAR_PATH.exists() {
        clear_immutable_flag(&HANDOFF_VAR_PATH)?;
    }

    std::fs::write(&*HANDOFF_VAR_PATH, buf)
}

pub fn take() -> Result<Option<Handoff>> {
    //Read the handoff data (if available)
    let data = match std::fs::read(&*HANDOFF_VAR_PATH) {
        Ok(data) => {
            clear_immutable_flag(&HANDOFF_VAR_PATH)?;
            std::fs::remove_file(&*HANDOFF_VAR_PATH)?;
            data
        }
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err),
    };

    //Decode the handoff data
    let Some((timestamp, user)) = data.get(4..).and_then(|d| d.split_first_chunk()) else {
        return Err(Error::new(ErrorKind::InvalidData, "truncated handoff data"));
    };

    Ok(Some(Handoff {
        timestamp: UNIX_EPOCH + Duration::from_secs(u64::from_le_bytes(*timestamp)),
        user: std::str::from_utf8(user)
            .map_err(|err| Error::new(ErrorKind::InvalidData, err))?
            .into(),
    }))
}
