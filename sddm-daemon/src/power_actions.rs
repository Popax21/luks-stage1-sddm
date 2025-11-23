use std::{
    io::{BufRead, Read, Write},
    os::unix::net::UnixStream,
};

use anyhow::{Context, Result, bail, ensure};
use smol::lock::Mutex;
use zbus::zvariant;

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
    dbus_client: Mutex<DBusClient>,
    capable_acts: [bool; PowerAction::ALL_ACTIONS.len()],
}

impl PowerActionClient {
    pub async fn connect() -> Result<PowerActionClient> {
        //We usually don't run with a D-Bus broker in the initrd, so connect to the manager directly
        let mut dbus_client = DBusClient::connect("/run/systemd/private")
            .await
            .context("failed to connect to private systemd D-Bus socket")?;

        //Check which power actions are available
        let mut capable_acts = [false; PowerAction::ALL_ACTIONS.len()];
        for act in PowerAction::ALL_ACTIONS {
            match Self::check_action(&mut dbus_client, act).await {
                Ok(_) => capable_acts[act as usize] = true,
                Err(err) => {
                    eprintln!("power action {act:?} unavailable: {err:#}");
                }
            }
        }

        Ok(PowerActionClient {
            dbus_client: Mutex::new(dbus_client),
            capable_acts,
        })
    }

    async fn check_action(dbus_client: &mut DBusClient, act: PowerAction) -> Result<()> {
        let (unit_obj,) = dbus_client
            .call::<(&str,), (zvariant::OwnedObjectPath,)>(
                "org.freedesktop.systemd1",
                "/org/freedesktop/systemd1",
                "org.freedesktop.systemd1.Manager",
                "LoadUnit",
                &(act.systemd_target(),),
            )
            .await
            .with_context(|| format!("failed to load systemd target {:?}", act.systemd_target()))?;

        let (can_start,) = dbus_client
            .call::<(&str, &str), (zvariant::OwnedValue,)>(
                "org.freedesktop.systemd1",
                &unit_obj,
                "org.freedesktop.DBus.Properties",
                "Get",
                &("org.freedesktop.systemd1.Unit", "CanStart"),
            )
            .await
            .with_context(|| format!("failed to load systemd target {:?}", act.systemd_target()))?;

        if can_start.downcast_ref()? {
            Ok(())
        } else {
            Err(anyhow::anyhow!(
                "systemd target {:?} can't be started",
                act.systemd_target()
            ))
        }
    }

    pub const fn can_perform_action(&self, act: PowerAction) -> bool {
        self.capable_acts[act as usize]
    }

    pub async fn perform_action(&self, act: PowerAction) {
        let mut dbus_client = self.dbus_client.lock().await;
        if let Err(err) = dbus_client
            .call::<(&str, &str), (zvariant::OwnedObjectPath,)>(
                "org.freedesktop.systemd1",
                "/org/freedesktop/systemd1",
                "org.freedesktop.systemd1.Manager",
                "StartUnit",
                &(act.systemd_target(), "replace-irreversibly"),
            )
            .await
        {
            eprintln!("failed to perform power action {act:?}: {err:#}")
        }
    }
}

//The manager D-Bus impl isn't spec compliant, so we have to slightly reinvent the wheel here
struct DBusClient {
    connection: zbus::conn::socket::BoxedSplit,
    recv_buf: Vec<u8>,
}

impl DBusClient {
    async fn connect(path: &str) -> Result<Self> {
        let mut connection = UnixStream::connect(path)?;

        let recv_buf = Self::authenticate(&mut connection)
            .await
            .context("authentication failure")?;

        Ok(DBusClient {
            connection: smol::Async::new(connection).unwrap().into(),
            recv_buf,
        })
    }

    async fn authenticate(mut conn: impl Read + Write) -> Result<Vec<u8>> {
        conn.write_all(b"\x00AUTH EXTERNAL 30\r\nBEGIN\r\n")?;

        let mut reply = String::new();
        let mut reader = std::io::BufReader::new(conn);
        reader.read_line(&mut reply)?;
        ensure!(reply.starts_with("OK"), "{:?}", reply.trim());

        Ok(reader.buffer().into())
    }

    async fn call<
        A: serde::Serialize + zvariant::DynamicType,
        R: for<'a> zvariant::DynamicDeserialize<'a>,
    >(
        &mut self,
        dst: impl TryInto<zbus::names::BusName<'_>, Error = impl Into<zbus::Error>>,
        path: impl TryInto<zvariant::ObjectPath<'_>, Error = impl Into<zbus::Error>>,
        interface: impl TryInto<zbus::names::InterfaceName<'_>, Error = impl Into<zbus::Error>>,
        method: impl TryInto<zbus::names::MemberName<'_>, Error = impl Into<zbus::Error>>,
        args: &A,
    ) -> Result<R> {
        use zbus::conn::socket::{ReadHalf, WriteHalf};

        //Send the method call message
        let call_msg = zbus::Message::method_call(path, method)?
            .destination(dst)?
            .interface(interface)?
            .build(args)?;

        WriteHalf::send_message(self.connection.write_mut(), &call_msg).await?;

        //Receive the method return reply message
        loop {
            let reply = ReadHalf::receive_message(
                self.connection.read_mut(),
                0,
                &mut self.recv_buf,
                &mut Vec::new(),
            )
            .await?;

            // - we should be checking the reply sequence number here, however
            //   trying to deserialize the header causes an explosion :)
            match reply.message_type() {
                zbus::message::Type::MethodReturn => return Ok(reply.body().deserialize()?),
                zbus::message::Type::Error => {
                    // - same issue here trying to access the error name :)
                    bail!("D-Bus error: {:?}", reply.body().deserialize::<&str>()?);
                }
                _ => {}
            }
        }
    }
}
