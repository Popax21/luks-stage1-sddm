use anyhow::{Context, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerAction {
    PowerOff,
    Reboot,
    Suspend,
    Hibernate,
    HybridSleep,
}

impl PowerAction {
    pub const ALL_ACTIONS: [PowerAction; 5] = [
        PowerAction::PowerOff,
        PowerAction::Reboot,
        PowerAction::Suspend,
        PowerAction::Hibernate,
        PowerAction::HybridSleep,
    ];

    fn systemd_target(self) -> &'static str {
        match self {
            PowerAction::PowerOff => "poweroff.target",
            PowerAction::Reboot => "reboot.target",
            PowerAction::Suspend => "suspend.target",
            PowerAction::Hibernate => "hibernate.target",
            PowerAction::HybridSleep => "hybrid-sleep.target",
        }
    }
}

pub struct PowerActionClient {
    manager_proxy: Systemd1ManagerProxy<'static>,
    capable_acts: [bool; PowerAction::ALL_ACTIONS.len()],
}

impl PowerActionClient {
    pub async fn connect() -> Result<PowerActionClient> {
        //We usually don't run with a D-Bus broker in the initrd, so connect to the manager directly
        //FIXME: there's no handshake; use AuthenticatedSocket
        let conn = match zbus::connection::Builder::address("unix:path=/run/systemd/private")
            .unwrap()
            .build()
            .await
        {
            Ok(c) => c,
            Err(err) => {
                eprintln!("failed to connect to private systemd D-Bus socket: {err:#}");
                eprintln!("falling back to regular system D-Bus broker (if available)...");

                zbus::Connection::system()
                    .await
                    .context("failed to open system D-Bus connection")?
            }
        };

        let mut client = PowerActionClient {
            manager_proxy: Systemd1ManagerProxy::new(&conn).await?,
            capable_acts: Default::default(),
        };

        //Check which power actions are available
        for act in PowerAction::ALL_ACTIONS {
            match client.manager_proxy.load_unit(act.systemd_target()).await {
                Ok(_) => client.capable_acts[act as usize] = true,
                Err(err) => {
                    eprintln!(
                        "power action {act:?} unavailable: systemd target {target:?} is unavailable: {err:#}",
                        target = act.systemd_target(),
                    );
                }
            }
        }

        Ok(client)
    }

    pub const fn can_perform_action(&self, act: PowerAction) -> bool {
        self.capable_acts[act as usize]
    }

    pub async fn perform_action(&self, act: PowerAction) {
        if let Err(err) = self
            .manager_proxy
            .start_unit(act.systemd_target(), "replace-irreversibly")
            .await
        {
            eprintln!("failed to perform power action {act:?}: {err:#}")
        }
    }
}

#[zbus::proxy(
    interface = "org.freedesktop.systemd1.Manager",
    default_service = "org.freedesktop.systemd1",
    default_path = "/org/freedesktop/systemd1"
)]
trait Systemd1Manager {
    fn load_unit(&self, name: &str) -> zbus::Result<zbus::zvariant::OwnedObjectPath>;
    fn start_unit(&self, name: &str, mode: &str) -> zbus::Result<zbus::zvariant::OwnedObjectPath>;
}
