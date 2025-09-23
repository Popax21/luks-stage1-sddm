use std::{collections::HashSet, path::Path, process::ExitCode, sync::Arc};

mod control_server;
mod password_agent;
mod sddm_config;

use self::{
    control_server::{GreeterController, greeter_control_server},
    password_agent::PasswordRequest,
    sddm_config::SddmConfig,
};
use smol::{lock::Mutex, process::Command, stream::StreamExt};
use zeroize::Zeroizing;

fn main() -> ExitCode {
    //Parse the SDDM config file we're given
    let Some(sddm_config) = std::env::args().nth(2) else {
        eprintln!(
            "Usage: {:?} <SDDM config file>",
            std::env::current_exe().unwrap_or_default()
        );
        std::process::exit(1);
    };
    let sddm_config = SddmConfig::load_from_file(Path::new(&sddm_config))
        .expect("failed to load SDDM config file");

    //Setup an abort panic handler; we should never panic, and we don't have any panic propagation / handling in place
    let default_panic = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        default_panic(info);
        std::process::abort();
    }));

    //Register a signal handler for SIGTERM / SIGINT
    let mut signals =
        async_signal::Signals::new([async_signal::Signal::Term, async_signal::Signal::Int])
            .expect("failed to register terminating signal handlers");

    //Start listening for password requests from systemd
    let pw_reqs = PasswordRequest::listen().expect("failed to listen for password requests");

    smol::block_on(async {
        let controller = Arc::new(Controller::new());

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

            let cmd = if let Some(theme) = &sddm_config.theme {
                // - if we have a theme configured, pass that to the greeter
                cmd.arg("--theme").arg(theme)
            } else {
                cmd
            };

            cmd.spawn().expect("failed to start SDDM greeter")
        };

        //Wait until we receive a SIGTERM / SIGINT signal, or the greeter finishes
        smol::future::or(
            async {
                signals
                    .next()
                    .await
                    .unwrap()
                    .expect("failed to wait for a terminating signal");
            },
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

        //Retrieve the greeter status
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
    request_tx: smol::channel::Sender<PasswordRequest>,
    login_lock: Mutex<LoginState>,
}

struct LoginState {
    request_rx: smol::channel::Receiver<PasswordRequest>,
    processed_ids: HashSet<String>,
}

impl Controller {
    fn new() -> Controller {
        let (request_tx, request_rx) = smol::channel::unbounded();
        Controller {
            request_tx,
            login_lock: Mutex::new(LoginState {
                request_rx,
                processed_ids: HashSet::new(),
            }),
        }
    }

    fn process_request(&self, req: PasswordRequest) {
        println!("queuing password request from {}", req.id.as_ref().unwrap());

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

        //Receive a request to process
        while let Ok(req) = state.request_rx.recv().await {
            //Check if we processed this request already; if yes, then the password wasn't correct, so bail
            let id = req.id.as_ref().unwrap();
            if !state.processed_ids.insert(id.clone()) {
                eprintln!("got another password request from {id}; login failed");
                msg_sender(&format!("failed to unlock {id}"));

                state.processed_ids.clear();
                return false;
            }

            //Answer the request
            println!("responding to password request from {id}");

            if let Err(err) = req.reply(Some(password.clone())).await {
                eprintln!("failed to reply to password request: {err:?}")
            }
        }

        //The transmitting end was closed; this means that the login was successful & we're shutting down
        true
    }

    fn can_shutdown(&self) -> bool {
        true
    }
    fn shutdown(&self) {}

    fn can_reboot(&self) -> bool {
        true
    }
    fn reboot(&self) {}

    fn can_suspend(&self) -> bool {
        true
    }
    fn suspend(&self) {}

    fn can_hibernate(&self) -> bool {
        false
    }
    fn hibernate(&self) {}

    fn can_hybrid_sleep(&self) -> bool {
        false
    }
    fn hybrid_sleep(&self) {}
}
