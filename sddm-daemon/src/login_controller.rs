use std::path::PathBuf;
use std::{collections::HashSet, path::Path};

use crate::power_actions::{PowerAction, PowerActionClient};

use crate::{
    control_server::GreeterController, password_agent::PasswordRequest, sddm_config::SddmConfig,
};
use smol::lock::Mutex;
use smol::stream::StreamExt;
use zeroize::Zeroizing;

pub struct LoginController {
    pub sddm_config: SddmConfig,
    power_client: Option<PowerActionClient>,
    request_tx: smol::channel::Sender<PasswordRequest>,
    login_lock: Mutex<LoginState>,
}

struct LoginState {
    request_rx: smol::channel::Receiver<PasswordRequest>,
    pending_request: Option<PasswordRequest>,
    login_request: Option<LoginRequest>,
}

pub struct LoginRequest {
    pub user: String,
    pub password: Zeroizing<Box<str>>,
    pub session: PathBuf,
}

impl LoginController {
    pub fn new(sddm_config: SddmConfig, power_client: Option<PowerActionClient>) -> Self {
        let (request_tx, request_rx) = smol::channel::unbounded();
        Self {
            sddm_config,
            power_client,
            request_tx,
            login_lock: Mutex::new(LoginState {
                request_rx,
                pending_request: None,
                login_request: None,
            }),
        }
    }

    pub async fn process_pw_requests(&self) {
        let pw_reqs = PasswordRequest::listen().expect("failed to listen for password requests");
        smol::pin!(pw_reqs);

        println!("listening for password requests...");
        while let Some(req) = pw_reqs.next().await {
            self.process_request(req);
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

        let canon_path = std::fs::canonicalize(path).unwrap();

        if !self
            .sddm_config
            .luks_devices
            .iter()
            .any(|dev| std::fs::canonicalize(dev).unwrap() == canon_path)
        {
            println!("ignoring password request for non-configured LUKS device {path:?}");
            return;
        }

        //Queue the request for processing
        println!("queuing password request for LUKS device {path:?}");

        self.request_tx
            .try_send(req)
            .expect("failed to queue password request");
    }

    pub async fn complete_request(&self) -> Option<LoginRequest> {
        assert!(self.request_tx.close());
        self.login_lock.lock().await.login_request.take()
    }
}

impl GreeterController for LoginController {
    async fn login(
        &self,
        user: &str,
        password: Zeroizing<Box<str>>,
        session: &Path,
        mut msg_sender: impl FnMut(&str),
    ) -> bool {
        let mut state = self.login_lock.lock().await;
        let state = &mut *state;

        //Stash the login request so we can hand it over as part of the shutdown sequence
        // - do this right away since the greeter can shut down before us, which cancels this Future early
        let LoginRequest { password, .. } = state.login_request.insert(LoginRequest {
            user: user.to_owned(),
            password,
            session: session.to_owned(),
        });

        //Process password requests
        let mut processed_ids = HashSet::<String>::new();

        loop {
            //Process the currently pending request
            let req = match &state.pending_request {
                Some(req) => req,
                None => {
                    //We have no stashed request, so receive a new request to process
                    if let Ok(req) = state.request_rx.recv().await {
                        &*state.pending_request.insert(req)
                    } else {
                        //The transmitting end was closed; this means that the unlock was successful / we're shutting down
                        return true;
                    }
                }
            };

            //Check if we processed this request already; if yes, then the password wasn't correct, so bail
            let id = req.id.as_ref().unwrap();
            if !processed_ids.insert(id.clone()) {
                eprintln!("got another password request from {id}; login failed");
                msg_sender(&format!("failed to unlock {id}"));

                state.login_request = None;
                return false;
            }

            //Answer the request
            // - prefix the slot key with `<user>#` to bind the LUKS slot to a specific user identity
            let slot_key = Zeroizing::new(format!("{user}#{}", &**password).into_boxed_str());

            println!("responding to password request from {id}");

            let req = state.pending_request.take().unwrap();
            if let Err(err) = req.reply(Some(slot_key)) {
                eprintln!("failed to reply to password request: {err:#}")
            }
        }
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
