use std::{path::Path, process::ExitCode, time::Duration};

mod control_server;
mod password_agent;
mod sddm_config;

use self::{
    control_server::{GreeterController, greeter_control_server},
    password_agent::PasswordRequest,
    sddm_config::SddmConfig,
};
use smol::{process::Command, stream::StreamExt};
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

    //Start listening for password requests from systemd
    let pw_reqs = PasswordRequest::listen().expect("failed to listen for password requests");

    smol::block_on(async {
        //Start listening for systemd password requests
        let pw_req_handler = smol::spawn(async move {
            smol::pin!(pw_reqs);

            println!("listening for password requests...");
            while let Some(req) = pw_reqs.next().await {
                println!("handling password request {req:?}");
                //TODO
            }
        });

        //Start an SDDM control server with an associated Unix socket
        let socket_path =
            std::env::temp_dir().join(format!("stage1-sddm-greeter-{}", std::process::id()));

        let control_server = smol::spawn(greeter_control_server(socket_path.clone(), Controller));

        //Start the SDDM greeter
        let mut cmd = Command::new(option_env!("EXE_SDDM_GREETER").unwrap_or("sddm-greeter-qt6"));
        let cmd = cmd.arg("--socket").arg(&socket_path);

        let cmd = if let Some(theme) = &sddm_config.theme {
            // - if we have a theme configured, pass that to the greeter
            cmd.arg("--theme").arg(theme)
        } else {
            cmd
        };

        //Wait for the greeter to finish
        let greeter_status = cmd.status().await.expect("failed to run SDDM greeter");

        //Shutdown
        control_server.cancel().await;
        pw_req_handler.cancel().await;

        if greeter_status.success() {
            ExitCode::SUCCESS
        } else {
            eprintln!("greeter exited with status {greeter_status}");
            ExitCode::FAILURE
        }
    })
}

struct Controller;
impl GreeterController for Controller {
    async fn login(
        &self,
        user: &str,
        password: Zeroizing<Box<str>>,
        mut msg_sender: impl FnMut(&str),
    ) -> bool {
        msg_sender("Unlocking...");
        smol::Timer::after(Duration::from_secs(3)).await;
        false
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
