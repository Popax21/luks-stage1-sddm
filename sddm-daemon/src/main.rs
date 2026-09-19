use std::{os::fd::AsRawFd, path::Path, process::ExitCode, sync::Arc, time::Duration};

mod control_server;
mod failsafe;
mod login_controller;
mod password_agent;
mod power_actions;
mod sddm_config;

use crate::{
    control_server::greeter_control_server,
    login_controller::LoginController,
    power_actions::PowerActionClient,
    sddm_config::{SddmConfig, write_transient_sddm_config},
};
use smol::{future::FutureExt, process::Command, stream::StreamExt};

fn main() -> ExitCode {
    //Parse the SDDM config file we're given
    let Some(sddm_config_path) = std::env::args().nth(1) else {
        eprintln!(
            "Usage: {:?} <SDDM config file>",
            std::env::current_exe().unwrap_or_default()
        );
        return ExitCode::FAILURE;
    };

    let sddm_config_path = Path::new(&sddm_config_path);
    let sddm_config =
        SddmConfig::load_from_file(sddm_config_path).expect("failed to load SDDM config file");

    //Setup an abort panic handler; we should never panic, and we don't have any panic propagation / handling in place
    let default_panic = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        default_panic(info);
        std::process::abort();
    }));

    //Force-claim ownership of the tty associated with our VT (i.e. /dev/tty1) to prevent systemd from showing password prompts there
    let _tty_claim = match claim_tty() {
        Ok(c) => Some(c),
        Err(err) => {
            eprintln!("failed to claim fbcon VT TTY ownership: {err:#}");
            None
        }
    };

    //Enter a private mount namespace so we can properly survive the sysroot pivot
    unshare_mount_ns().expect("failed to unshare mount NS");

    // - the closure tells us whether we are using a nullfs rootfs (which leaves the initrd intact)
    let initrd_survives_pivot = std::env::var("INITRD_SURVIVES_PIVOT").as_deref() == Ok("true");

    //Start listening for password requests from systemd
    smol::block_on(async {
        //Setup the login controller
        let power_client = match PowerActionClient::connect().await {
            Ok(c) => Some(c),
            Err(err) => {
                eprintln!("failed to connect power action client: {err:#}");
                None
            }
        };

        let controller = Arc::new(LoginController::new(sddm_config, power_client));

        //Start listening for systemd password requests
        let pw_req_handler = smol::spawn({
            let controller = controller.clone();
            async move {
                controller.process_pw_requests().await;
            }
        });

        //Start an SDDM control server with an associated Unix socket
        let socket_path =
            std::env::temp_dir().join(format!("stage1-sddm-greeter-{}", std::process::id()));

        let control_server = smol::spawn(greeter_control_server(
            socket_path.clone(),
            controller.clone(),
        ));

        //Wait for a DRI/DRM device to become available
        if !wait_for_dri_device()
            .await
            .expect("failed to wait for DRI/DRM device")
        {
            eprintln!("no DRI/DRM device became available");
            return ExitCode::FAILURE;
        }

        //Register a failsafe handler which listens for keyboard events from evdev
        let failsafe_signal = match failsafe::start_failsafe().await {
            Ok(s) => s,
            Err(err) => {
                eprintln!("failed to initialize evdev failsafe: {err:#}");
                return ExitCode::FAILURE;
            }
        };

        //Start the SDDM greeter
        let mut greeter = {
            let mut cmd = Command::new(&controller.sddm_config.greeter);
            let cmd = cmd
                .arg("--socket")
                .arg(&socket_path)
                .env("SDDM_CONFIG", sddm_config_path);

            let cmd = if let Some(theme) = &controller.sddm_config.theme {
                // - if we have a theme configured, pass that to the greeter
                cmd.arg("--theme").arg(theme)
            } else {
                cmd
            };

            cmd.spawn().expect("failed to start SDDM greeter")
        };

        //Pivot/chroot into /sysroot once it's mounted (if needed)
        let sysroot_pivot_task =
            smol::spawn(handle_sysroot_pivot(greeter.id(), initrd_survives_pivot));

        //Wait until we receive a SIGTERM / SIGINT signal, or the greeter finishes
        let mut signals =
            async_signal::Signals::new([async_signal::Signal::Term, async_signal::Signal::Int])
                .expect("failed to register terminating signal handlers");

        sd_notify::notify(true, &[sd_notify::NotifyState::Ready])
            .expect("failed to send sd-notify ready notification");

        let mut failsafe_engaged = false;
        smol::future::or(
            smol::future::or(
                async {
                    signals
                        .next()
                        .await
                        .unwrap()
                        .expect("failed to wait for a terminating signal");
                },
                async {
                    failsafe_signal.await;
                    failsafe_engaged = true;
                },
            ),
            async {
                greeter
                    .status()
                    .await
                    .expect("failed to wait for SDDM greeter");
            },
        )
        .await;

        if failsafe_engaged {
            eprintln!("bailing on failsafe engagement");

            smol::future::or(
                async {
                    _ = greeter.kill();
                    _ = greeter.status().await;
                },
                async {
                    smol::Timer::after(Duration::from_millis(1500)).await;
                },
            )
            .await;

            return ExitCode::FAILURE;
        }

        //Shutdown password request handling
        pw_req_handler.cancel().await;

        //Shutdown the greeter control server; this will make the greeter shutdown as well
        control_server.cancel().await;

        //Wait for the greeter to exit
        let greeter_status = greeter
            .status()
            .await
            .expect("failed to wait for SDDM greeter");

        if !greeter_status.success() {
            // - something went wrong; bail out just in case
            eprintln!("greeter exited with status {greeter_status}");
            return ExitCode::FAILURE;
        }

        //Hand off the login request to the proper service if we were processing one
        if let Some(request) = controller.complete_request().await {
            //We got a pending login request before shutting down; prepare for a handoff to the proper SDDM service
            if sysroot_pivot_task.is_finished() {
                write_transient_sddm_config(&request, initrd_survives_pivot)
                    .expect("failed to write transient SDDM config");

                println!(
                    "wrote transient SDDM handoff config for user {}",
                    &request.user
                );
            } else if crate::is_hibernation_resume_queued().await {
                //We are resuming from hibernation; handoff to the hibernation helper
                let handoff = luks_stage1_hibernation_handoff::Handoff::new(request.user);
                match luks_stage1_hibernation_handoff::store(&handoff) {
                    Ok(()) => {
                        println!("wrote hibernation handoff data for user {}", &handoff.user);
                    }
                    Err(err) => {
                        eprintln!("failed to write hibernation handoff data: {err:#}");
                    }
                }
            } else {
                eprintln!(
                    "can't handoff pending login request since we didn't pivot into the new sysroot yet"
                );
            }
        };

        ExitCode::SUCCESS
    })
}

fn unshare_mount_ns() -> nix::Result<()> {
    use nix::mount::{MsFlags, mount};
    use nix::sched::{CloneFlags, unshare};

    //Unshare the mount namespace
    unshare(CloneFlags::CLONE_NEWNS)?;

    //Setup mount propagation - inherit mounts from the host, but not the other way around
    mount(
        None::<&str>,
        "/",
        None::<&str>,
        MsFlags::MS_REC | MsFlags::MS_SLAVE,
        None::<&str>,
    )
}

async fn handle_sysroot_pivot(greeter_pid: u32, initrd_survives_pivot: bool) {
    use nix::mount::{MsFlags, mount};

    //Wait for a SIGUSR1 signal which tells us that /sysroot was successfully mounted
    async_signal::Signals::new([async_signal::Signal::Usr1])
        .expect("failed to register SIGUSR1 signal handler")
        .next()
        .await
        .unwrap()
        .expect("failed to wait for SIGUSR1");

    eprintln!("got SIGUSR1 - preparing for /sysroot pivot");

    //Detach our mount NS so we are isolated from systemd switch-root
    mount(
        None::<&str>,
        "/",
        None::<&str>,
        MsFlags::MS_REC | MsFlags::MS_PRIVATE,
        None::<&str>,
    )
    .expect("failed to detach mount namespace");

    if initrd_survives_pivot {
        // - this is a modern system with a nullfs rootfs -> systemd leaves the initrd intact
        eprintln!(" - initrd survives /sysroot pivot, no need to pivot ourselves");
        return;
    }

    //Otherwise, systemd wipes the initrd, so we need to chroot to have a functional / root

    // - remount our view of the post-pivot Nix store to also include the closure overlay
    // - this does not include paths from the initrd, so best effort
    if let Err(err) = mount(
        Some("overlay"),
        "/sysroot/nix/store",
        Some("overlay"),
        MsFlags::empty(),
        Some("lowerdir=/sysroot/nix/store:/nix/store"),
    ) {
        eprintln!("failed to overlay SDDM closure onto /sysroot: {err}");
    }

    // - chroot ourselves into the new root
    std::env::set_current_dir("/sysroot").expect("failed to chdir into sysroot");
    std::os::unix::fs::chroot(".").expect("failed to chroot into sysroot");

    // - relay the pivot signal to the greeter
    nix::sys::signal::kill(
        nix::unistd::Pid::from_raw(greeter_pid as i32),
        nix::sys::signal::Signal::SIGUSR1,
    )
    .expect("failed to relay pivot signal to greeter");
}

fn claim_tty() -> std::io::Result<std::fs::File> {
    let tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty1")?;

    //Claim the terminal
    nix::ioctl_write_int_bad!(tiocsctty, nix::libc::TIOCSCTTY);
    unsafe { tiocsctty(tty.as_raw_fd(), 1) }?;

    //Disable echoing (since user input would otherwise be visible once we terminate)
    let mut termios = nix::sys::termios::tcgetattr(&tty)?;

    termios
        .local_flags
        .set(nix::sys::termios::LocalFlags::ECHO, false);
    termios
        .local_flags
        .set(nix::sys::termios::LocalFlags::ICANON, false);

    nix::sys::termios::tcsetattr(&tty, nix::sys::termios::SetArg::TCSANOW, &termios)?;

    Ok(tty)
}

async fn wait_for_dri_device() -> std::io::Result<bool> {
    let mut spin_attempt = 0;
    loop {
        //Check for a DRI device
        if std::fs::exists("/dev/dri")? {
            for ent in std::fs::read_dir("/dev/dri")? {
                if ent?
                    .file_name()
                    .to_str()
                    .is_some_and(|n| n.starts_with("card"))
                {
                    return Ok(true);
                }
            }
        }

        //No DRI device - wait for a bit, but give up if it takes too long
        if spin_attempt == 1 {
            eprintln!("no DRI/DRM device available - spinning for a while...");
        }

        spin_attempt += 1;

        if spin_attempt > 30 {
            return Ok(false);
        }

        smol::Timer::after(std::time::Duration::from_millis(200)).await;
    }
}

async fn is_hibernation_resume_queued() -> bool {
    #[zbus::proxy(
        interface = "org.freedesktop.systemd1.Manager",
        default_service = "org.freedesktop.systemd1",
        default_path = "/org/freedesktop/systemd1"
    )]
    trait SystemdManager {
        fn get_unit(&self, name: &str) -> zbus::Result<zbus::zvariant::OwnedObjectPath>;
    }

    async fn access_hibernate_resume() -> zbus::Result<()> {
        //Connect to the system D-Bus
        let conn = zbus::conn::Builder::system()?
            .internal_executor(false)
            .build()
            .await?;

        let poll_conn = async {
            loop {
                conn.executor().tick().await;
            }
        };

        //Attempt to access the systemd-hibernate-resume service
        SystemdManagerProxy::new(&conn)
            .await?
            .get_unit("systemd-hibernate-resume.service")
            .race(poll_conn)
            .await?;

        Ok(())
    }

    match access_hibernate_resume().await {
        Ok(()) => true,
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "org.freedesktop.systemd1.NoSuchUnit" =>
        {
            false
        }
        Err(err) => {
            eprintln!("hibernation resume probe failed: {err:#}");
            false
        }
    }
}
