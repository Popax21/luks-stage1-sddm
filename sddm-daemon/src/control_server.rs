use std::{io::ErrorKind, mem::MaybeUninit, ops::DerefMut, path::PathBuf, str, sync::Arc};

use anyhow::Result;
use smol::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::unix::{UnixListener, UnixStream},
};
use zeroize::Zeroizing;

pub trait GreeterController: Send + Sync + 'static {
    fn login(
        &self,
        user: &str,
        password: Zeroizing<Box<str>>,
        msg_sender: impl FnMut(&str) + Send + Sync,
    ) -> impl Future<Output = bool> + Send + Sync;

    fn can_shutdown(&self) -> bool;
    fn shutdown(&self);

    fn can_reboot(&self) -> bool;
    fn reboot(&self);

    fn can_suspend(&self) -> bool;
    fn suspend(&self);

    fn can_hibernate(&self) -> bool;
    fn hibernate(&self);

    fn can_hybrid_sleep(&self) -> bool;
    fn hybrid_sleep(&self);
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
                eprintln!("failed to handle greeter connection {conn_id}: {err:?}");
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
    //Receive messages from the connection
    loop {
        let msg = {
            let mut buf = [0u8; 4];
            if let Err(err) = conn.read_exact(&mut buf).await {
                return if err.kind() == ErrorKind::UnexpectedEof {
                    Ok(())
                } else {
                    Err(err.into())
                };
            }
            u32::from_be_bytes(buf)
        };

        match msg {
            _ if msg == GreeterMessages::Connect as u32 => {
                //Initial handshake; send the controller's capabilities / hostname
                let mut caps = 0;
                if controller.can_shutdown() {
                    caps |= Capability::PowerOff as u32;
                }
                if controller.can_reboot() {
                    caps |= Capability::Reboot as u32;
                }
                if controller.can_suspend() {
                    caps |= Capability::Suspend as u32;
                }
                if controller.can_hibernate() {
                    caps |= Capability::Hibernate as u32;
                }
                if controller.can_hybrid_sleep() {
                    caps |= Capability::HybridSleep as u32;
                }

                conn.write_all(&u32::to_be_bytes(DaemonMessages::Capabilities as u32))
                    .await?;
                conn.write_all(&u32::to_be_bytes(caps)).await?;

                if let Some(hostname) = gethostname::gethostname().to_str() {
                    conn.write_all(&u32::to_be_bytes(DaemonMessages::HostName as u32))
                        .await?;
                    send_string(&mut conn, hostname).await?;
                }
            }

            //Login requests
            _ if msg == GreeterMessages::Login as u32 => {
                //Read the username / password
                let user = recv_string(&mut conn).await?;
                let password = Zeroizing::new(recv_string(&mut conn).await?);

                //Read the session the user selected, tho we ignore this info
                let mut _ses_type = [0u8; 4];
                conn.read_exact(&mut _ses_type).await?;
                let _ses_filename = recv_string(&mut conn).await?;

                //Forward the request to the controller
                println!("handling login request from greeter for user {user:?}");

                let login_ok =
                    handle_login_request(&mut conn, &user, password, &*controller).await?;

                println!(
                    "finished handling login request for user {user:?}, result: {}",
                    if login_ok { "OK" } else { "failure" }
                );

                if login_ok {
                    conn.write_all(&u32::to_be_bytes(DaemonMessages::LoginSucceeded as u32))
                        .await?;
                } else {
                    conn.write_all(&u32::to_be_bytes(DaemonMessages::LoginFailed as u32))
                        .await?;
                }
            }

            //Power action messages
            _ if msg == GreeterMessages::PowerOff as u32 => {
                controller.shutdown();
            }
            _ if msg == GreeterMessages::Reboot as u32 => {
                controller.reboot();
            }
            _ if msg == GreeterMessages::Suspend as u32 => {
                controller.suspend();
            }
            _ if msg == GreeterMessages::Hibernate as u32 => {
                controller.hibernate();
            }
            _ if msg == GreeterMessages::HybridSleep as u32 => {
                controller.hybrid_sleep();
            }

            _ => {
                eprintln!("unknown greeter control message {msg}")
            }
        }
    }
}

async fn handle_login_request(
    stream: &mut (impl AsyncWrite + Send + Sync + Unpin),
    user: &str,
    password: Zeroizing<Box<str>>,
    controller: &impl GreeterController,
) -> Result<bool> {
    let stream = smol::lock::Mutex::new(stream);

    let msg_exec = smol::Executor::new();
    msg_exec
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
                        .write_all(&u32::to_be_bytes(DaemonMessages::InformationMessage as u32))
                        .await?;
                    send_string(stream.deref_mut(), &msg).await?;

                    Ok::<_, anyhow::Error>(())
                }));
            };

            //Invoke the controller
            let login_ok = controller.login(user, password, msg_sender).await;

            //Finish sending information messages
            for t in msg_tasks {
                t.await?;
            }

            Ok(login_ok)
        })
        .await
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
enum GreeterMessages {
    Connect = 0,
    Login,
    PowerOff,
    Reboot,
    Suspend,
    Hibernate,
    HybridSleep,
}

#[repr(u32)]
enum DaemonMessages {
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
