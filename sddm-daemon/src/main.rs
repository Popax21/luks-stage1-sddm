use std::{collections::HashSet, os::fd::AsRawFd, path::Path, process::ExitCode, sync::Arc};

mod control_server;
mod failsafe;
mod password_agent;
mod power_actions;
mod sddm_config;

use crate::power_actions::{PowerAction, PowerActionClient};

use self::{
    control_server::{GreeterController, greeter_control_server},
    password_agent::PasswordRequest,
    sddm_config::SddmConfig,
};
use smol::{lock::Mutex, process::Command, stream::StreamExt};
use zeroize::Zeroizing;

fn main() -> ExitCode {
    //Parse the SDDM config file we're given
    let Some(sddm_config) = std::env::args().nth(1) else {
        eprintln!(
            "Usage: {:?} <SDDM config file>",
            std::env::current_exe().unwrap_or_default()
        );
        return ExitCode::FAILURE;
    };
    let sddm_config = SddmConfig::load_from_file(Path::new(&sddm_config))
        .expect("failed to load SDDM config file");

    //Setup an abort panic handler; we should never panic, and we don't have any panic propagation / handling in place
    let default_panic = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        default_panic(info);
        std::process::abort();
    }));

    //Force-claim ownership of the tty associated with our VT (i.e. /dev/tty1) to prevent systemd from showing password prompts there
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

    let _tty_claim = match claim_tty() {
        Ok(c) => Some(c),
        Err(err) => {
            eprintln!("failed to claim fbcon VT TTY ownership: {err:#}");
            None
        }
    };

    //Register a signal handler for SIGTERM / SIGINT
    let mut signals =
        async_signal::Signals::new([async_signal::Signal::Term, async_signal::Signal::Int])
            .expect("failed to register terminating signal handlers");

    //Register a failsafe handler which listens for keyboard events from evdev
    let failsafe_signal = match failsafe::start_failsafe() {
        Ok(s) => s,
        Err(err) => {
            eprintln!("failed to initialize evdev failsafe: {err:#}");
            return ExitCode::FAILURE;
        }
    };

    //Start listening for password requests from systemd
    let pw_reqs = PasswordRequest::listen().expect("failed to listen for password requests");

    smol::block_on(async {
        let power_client = match PowerActionClient::connect().await {
            Ok(c) => Some(c),
            Err(err) => {
                eprintln!("failed to connect power action client: {err:#}");
                None
            }
        };

        let controller = Arc::new(Controller::new(power_client, sddm_config));

        //Start listening for systemd password requests
        let pw_req_handler = smol::spawn({
            let controller = controller.clone();
            async move {
                smol::pin!(pw_reqs);

                println!("listening for password requests...");
                while let Some(req) = pw_reqs.next().await {
                    controller.process_request(req);
                }
            }
        });

        //Start an SDDM control server with an associated Unix socket
        let socket_path =
            std::env::temp_dir().join(format!("stage1-sddm-greeter-{}", std::process::id()));

        let control_server = smol::spawn(greeter_control_server(
            socket_path.clone(),
            controller.clone(),
        ));

        //Start the SDDM greeter
        let mut greeter = {
            let mut cmd =
                Command::new(option_env!("EXE_SDDM_GREETER").unwrap_or("sddm-greeter-qt6"));
            let cmd = cmd.arg("--socket").arg(&socket_path);

            let cmd = if let Some(theme) = &controller.sddm_config.theme {
                // - if we have a theme configured, pass that to the greeter
                cmd.arg("--theme").arg(theme)
            } else {
                cmd
            };

            cmd.spawn().expect("failed to start SDDM greeter")
        };

        //Wait until we receive a SIGTERM / SIGINT signal, or the greeter finishes
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

        //Shutdown password request handling
        pw_req_handler.cancel().await;
        controller.shutdown_controller();

        //Retrieve the greeter status, unless the failsafe was engaged, then kill it
        if failsafe_engaged {
            _ = greeter.kill();
        }

        let greeter_status = greeter
            .status()
            .await
            .expect("failed to wait for SDDM greeter");

        //Now shutdown the greeter control server
        control_server.cancel().await;

        if greeter_status.success() {
            ExitCode::SUCCESS
        } else {
            eprintln!("greeter exited with status {greeter_status}");
            ExitCode::FAILURE
        }
    })
}

struct Controller {
    power_client: Option<PowerActionClient>,
    request_tx: smol::channel::Sender<PasswordRequest>,
    login_lock: Mutex<LoginState>,
    sddm_config: SddmConfig,
}

struct LoginState {
    request_rx: smol::channel::Receiver<PasswordRequest>,
    pending_request: Option<PasswordRequest>,
    processed_ids: HashSet<String>,
}

impl Controller {
    fn new(power_client: Option<PowerActionClient>, sddm_config: SddmConfig) -> Controller {
        let (request_tx, request_rx) = smol::channel::unbounded();
        Controller {
            power_client,
            request_tx,
            login_lock: Mutex::new(LoginState {
                request_rx,
                pending_request: None,
                processed_ids: HashSet::new(),
            }),
            sddm_config,
        }
    }

    fn process_request(&self, req: PasswordRequest) {
        //Check if we should process this request
        let Some(path) = req
            .id
            .as_ref()
            .and_then(|id| id.strip_prefix("cryptsetup:"))
            .map(Path::new)
        else {
            println!("ignoring non-cryptsetup password request: {req:?}");
            return;
        };

        if !self.sddm_config.luks_devices.iter().any(|dev| dev == path) {
            println!("ignoring password request for non-configured LUKS device {path:?}");
            return;
        }

        //Queue the request for processing
        println!("queuing password request for LUKS device {path:?}");

        self.request_tx
            .try_send(req)
            .expect("failed to queue password request");
    }

    fn shutdown_controller(&self) {
        self.request_tx.close();
    }
}

impl GreeterController for Controller {
    async fn login(
        &self,
        _user: &str,
        password: Zeroizing<Box<str>>,
        mut msg_sender: impl FnMut(&str),
    ) -> bool {
        let mut state = self.login_lock.lock().await;

        //Receive a request to process, or if we already have a request from the last failed login attempt, process that
        while let Ok(req) = match state.pending_request.take() {
            Some(r) => Ok(r),
            None => state.request_rx.recv().await,
        } {
            //Check if we processed this request already; if yes, then the password wasn't correct, so bail
            let id = req.id.as_ref().unwrap();
            if !state.processed_ids.insert(id.clone()) {
                eprintln!("got another password request from {id}; login failed");
                msg_sender(&format!("failed to unlock {id}"));

                state.processed_ids.clear();
                state.pending_request = Some(req);
                return false;
            }

            //Answer the request
            println!("responding to password request from {id}");

            if let Err(err) = req.reply(Some(password.clone())) {
                eprintln!("failed to reply to password request: {err:#}")
            }
        }

        //The transmitting end was closed; this means that the login was successful & we're shutting down
        true
    }

    fn can_perform_power_action(&self, act: PowerAction) -> bool {
        self.power_client
            .as_ref()
            .is_some_and(|c| c.can_perform_action(act))
    }

    async fn perform_power_action(&self, act: PowerAction) {
        println!("performing power action {act:?}");

        self.power_client
            .as_ref()
            .expect("attempted to perform power action without power action client")
            .perform_action(act)
            .await
    }
}
