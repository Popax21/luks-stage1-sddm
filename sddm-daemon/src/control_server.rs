use std::{
    io::ErrorKind,
    mem::MaybeUninit,
    ops::DerefMut,
    path::{Path, PathBuf},
    str,
    sync::Arc,
};

use anyhow::{Result, bail, ensure};
use smol::{
    future::FutureExt,
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::unix::{UnixListener, UnixStream},
};
use zeroize::Zeroizing;

use crate::power_actions::PowerAction;

pub trait GreeterController: Send + Sync + 'static {
    fn login(
        &self,
        user: &str,
        password: Zeroizing<Box<str>>,
        session: &Path,
        msg_sender: impl FnMut(&str) + Send + Sync,
    ) -> impl Future<Output = bool> + Send;

    fn can_perform_power_action(&self, act: PowerAction) -> bool;
    fn perform_power_action(&self, act: PowerAction) -> impl Future<Output = ()> + Send;
}

pub async fn greeter_control_server(socket_path: PathBuf, controller: Arc<impl GreeterController>) {
    //Bind the socket and accept any connections from greeters
    let socket = UnixListener::bind(&socket_path).expect("failed to bind greeter control socket");

    let mut conns = Vec::new();
    loop {
        let (conn, _) = socket
            .accept()
            .await
            .expect("failed to accept greeter control socket connection");

        let conn_id = conns.len();
        let controller = controller.clone();
        conns.push(smol::spawn(async move {
            println!("accepted greeter control socket connection {conn_id}");
            if let Err(err) = greeter_control_connection(conn, controller).await {
                eprintln!("failed to handle greeter connection {conn_id}: {err:#}");
            } else {
                println!("greeter control socket connection {conn_id} was closed");
            }
        }));
    }
}

async fn greeter_control_connection(
    mut conn: UnixStream,
    controller: Arc<impl GreeterController>,
) -> Result<()> {
    //Perform the initial handshake
    match recv_msg(&mut conn).await? {
        Some(msg) => {
            ensure!(
                msg == GreeterMessage::Connect as u32,
                "unexpected first message: {msg}"
            );

            let mut caps = 0;
            for act in PowerAction::ALL_ACTIONS {
                if controller.can_perform_power_action(act) {
                    caps |= Capability::from(act) as u32;
                }
            }

            //Send the controller's capabilities / hostname
            conn.write_all(&u32::to_be_bytes(DaemonMessage::Capabilities as u32))
                .await?;
            conn.write_all(&u32::to_be_bytes(caps)).await?;

            if let Some(hostname) = gethostname::gethostname().to_str() {
                conn.write_all(&u32::to_be_bytes(DaemonMessage::HostName as u32))
                    .await?;
                send_string(&mut conn, hostname).await?;
            }
        }
        None => return Ok(()),
    }

    //Handle messages received from the connection
    let (err_tx, err_rx) = smol::channel::bounded(1);
    let exec = smol::Executor::new();

    let main_loop = async {
        let mut login_task = None;
        loop {
            match recv_msg(&mut conn).await? {
                //Login requests
                Some(msg) if msg == GreeterMessage::Login as u32 => {
                    //Read the username / password
                    let user = recv_string(&mut conn).await?;
                    let password = Zeroizing::new(recv_string(&mut conn).await?);

                    //Read the session the user selected
                    let mut _ses_type = [0u8; 4];
                    conn.read_exact(&mut _ses_type).await?;

                    let session = recv_string(&mut conn).await?;

                    //Forward the request to the controller
                    if !login_task.as_ref().is_none_or(smol::Task::is_finished) {
                        println!("ignoring concurrent login request for user {user:?}");
                        continue;
                    }

                    println!("handling login request from greeter for user {user:?}");

                    let conn = conn.clone();
                    let err_tx = err_tx.clone();
                    let controller = controller.clone();
                    login_task = Some(exec.spawn(async move {
                        if let Err(err) = handle_login_request(
                            conn,
                            &user,
                            password,
                            Path::new(&*session),
                            &*controller,
                        )
                        .await
                        {
                            _ = err_tx.try_send(err);
                        }
                    }));
                }

                //Power action messages
                Some(msg)
                    if PowerAction::ALL_ACTIONS
                        .into_iter()
                        .any(|a| msg == GreeterMessage::from(a) as u32) =>
                {
                    let act = PowerAction::ALL_ACTIONS
                        .into_iter()
                        .find(|&a| msg == GreeterMessage::from(a) as u32)
                        .unwrap();

                    controller.perform_power_action(act).await;
                }

                Some(msg) => bail!("unknown greeter control message {msg}"),
                None => return Ok(()),
            }
        }
    };

    exec.run(main_loop.or(async { Err(err_rx.recv().await.unwrap()) }))
        .await
}

async fn handle_login_request(
    stream: impl AsyncWrite + Send + Sync + Unpin,
    user: &str,
    password: Zeroizing<Box<str>>,
    session: &Path,
    controller: &impl GreeterController,
) -> Result<()> {
    let stream = smol::lock::Mutex::new(stream);

    let msg_exec = smol::Executor::new();
    let login_ok = msg_exec
        .run(async {
            //Setup information message handling
            let mut msg_tasks = Vec::new();
            let msg_sender = |msg: &str| {
                let msg = msg.to_string();
                msg_tasks.push(msg_exec.spawn(async {
                    let msg = msg; // - move msg into the closure

                    // - send the message to the greeter
                    let mut stream = stream.lock().await;
                    stream
                        .write_all(&u32::to_be_bytes(DaemonMessage::InformationMessage as u32))
                        .await?;
                    send_string(stream.deref_mut(), &msg).await?;

                    Ok::<_, anyhow::Error>(())
                }));
            };

            //Invoke the controller
            let login_ok = controller.login(user, password, session, msg_sender).await;

            println!(
                "finished handling login request for user {user:?}, result: {}",
                if login_ok { "OK" } else { "failure" }
            );

            //Finish sending information messages
            for t in msg_tasks {
                t.await?;
            }

            Ok::<_, anyhow::Error>(login_ok)
        })
        .await?;

    drop(msg_exec);

    //Reply with the correct answer message
    stream
        .into_inner()
        .write_all(&u32::to_be_bytes(if login_ok {
            DaemonMessage::LoginSucceeded
        } else {
            DaemonMessage::LoginFailed
        } as u32))
        .await?;

    Ok(())
}

async fn recv_msg(stream: &mut (impl AsyncRead + Unpin)) -> std::io::Result<Option<u32>> {
    let mut buf = [0u8; 4];
    match stream.read_exact(&mut buf).await {
        Ok(_) => Ok(Some(u32::from_be_bytes(buf))),
        Err(err)
            if matches!(
                err.kind(),
                ErrorKind::UnexpectedEof | ErrorKind::ConnectionReset
            ) =>
        {
            Ok(None)
        }
        Err(err) => Err(err),
    }
}

async fn recv_string(stream: &mut (impl AsyncRead + Unpin)) -> std::io::Result<Box<str>> {
    //Read the string length
    let mut len = {
        let mut buf = [0u8; 4];
        stream.read_exact(&mut buf).await?;
        u32::from_be_bytes(buf) as usize
    };

    if len == u32::MAX as usize {
        //Null marker
        return Ok(Box::from(""));
    } else if len == (u32::MAX - 1) as usize {
        //Extended length
        let mut buf = [0u8; 8];
        stream.read_exact(&mut buf).await?;
        len = u64::from_be_bytes(buf) as usize;
    }

    //Read the codepoints
    if len % 2 != 0 {
        return Err(std::io::ErrorKind::InvalidData.into());
    }

    // - the data we're reading might be sensitive, so be cautious and zeroize just in case
    let mut cps = Zeroizing::new(vec![0u16; len / 2]);

    stream
        .read_exact(unsafe {
            std::slice::from_raw_parts_mut(cps.as_mut_ptr().cast(), cps.len() * 2)
        })
        .await?;

    #[cfg(target_endian = "little")]
    cps.iter_mut().for_each(|w| *w = w.swap_bytes());

    //Construct the string from its codepoints, taking great care to not leave any stale codepoints in memory
    let mut str_len = 0;
    for c in char::decode_utf16(cps.iter().cloned()) {
        match c {
            Ok(c) => str_len += c.len_utf8(),
            Err(_) => return Err(std::io::ErrorKind::InvalidData.into()),
        }
    }

    let mut s = Box::new_uninit_slice(str_len);
    s.fill(MaybeUninit::zeroed());
    let mut s = unsafe { s.assume_init() };

    let mut off = 0;
    for c in char::decode_utf16(cps.iter().cloned()) {
        let c = c.unwrap();
        c.encode_utf8(&mut s[off..]);
        off += c.len_utf16();
    }

    Ok(unsafe { str::from_boxed_utf8_unchecked(s) })
}

async fn send_string(stream: &mut (impl AsyncWrite + Unpin), val: &str) -> std::io::Result<()> {
    let cps: Vec<u16> = val.encode_utf16().map(|w| w.to_be()).collect();
    let cps: &[u8] = unsafe { std::slice::from_raw_parts(cps.as_ptr().cast(), cps.len() * 2) };

    if !cps.is_empty() {
        if cps.len() < (u32::MAX - 1) as usize {
            stream
                .write_all(&u32::to_be_bytes(cps.len() as u32))
                .await?;
        } else {
            stream.write_all(&u32::to_be_bytes(u32::MAX - 1)).await?;
            stream
                .write_all(&u64::to_be_bytes(cps.len() as u64))
                .await?;
        }

        stream.write_all(cps).await?;
    } else {
        stream.write_all(&u32::MAX.to_be_bytes()).await?;
    }

    Ok(())
}

#[repr(u32)]
#[derive(Debug, Clone, Copy)]
enum GreeterMessage {
    Connect = 0,
    Login,
    PowerOff,
    Reboot,
    Suspend,
    Hibernate,
    HybridSleep,
}

impl From<PowerAction> for GreeterMessage {
    fn from(value: PowerAction) -> Self {
        match value {
            PowerAction::PowerOff => Self::PowerOff,
            PowerAction::Reboot => Self::Reboot,
            PowerAction::Suspend => Self::Suspend,
            PowerAction::Hibernate => Self::Hibernate,
            PowerAction::HybridSleep => Self::HybridSleep,
        }
    }
}

#[repr(u32)]
#[derive(Debug, Clone, Copy)]
enum DaemonMessage {
    HostName,
    Capabilities,
    LoginSucceeded,
    LoginFailed,
    InformationMessage,
}

#[repr(u32)]
enum Capability {
    PowerOff = 0b00001,
    Reboot = 0b00010,
    Suspend = 0b00100,
    Hibernate = 0b01000,
    HybridSleep = 0b10000,
}

impl From<PowerAction> for Capability {
    fn from(value: PowerAction) -> Self {
        match value {
            PowerAction::PowerOff => Self::PowerOff,
            PowerAction::Reboot => Self::Reboot,
            PowerAction::Suspend => Self::Suspend,
            PowerAction::Hibernate => Self::Hibernate,
            PowerAction::HybridSleep => Self::HybridSleep,
        }
    }
}
