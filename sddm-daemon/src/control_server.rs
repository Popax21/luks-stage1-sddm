use std::{ffi::OsStr, io::ErrorKind, os::unix::ffi::OsStrExt, path::PathBuf, pin::Pin};

use anyhow::Result;
use smol::{
    io::{AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::unix::{UnixListener, UnixStream},
};

pub async fn greeter_control_server(socket_path: PathBuf) {
    //Bind the socket and accept any connections from greeters
    let socket = UnixListener::bind(&socket_path).expect("failed to bind greeter control socket");

    let mut conns = Vec::new();
    loop {
        let (conn, _) = socket
            .accept()
            .await
            .expect("failed to accept greeter control socket connection");

        let conn_id = conns.len();
        conns.push(smol::spawn(async move {
            println!("accepted greeter control socket connection {conn_id}");
            if let Err(err) = greeter_control_connection(conn).await {
                eprintln!("failed to read message from greeter connection {conn_id}: {err:?}");
            } else {
                println!("greeter control socket connection {conn_id} was closed");
            }
        }));
    }
}

async fn greeter_control_connection(mut conn: UnixStream) -> Result<()> {
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
            u32::from_ne_bytes(buf)
        };

        match msg {
            _ if msg == GreeterMessages::Connect as u32 => {
                //Initial handshake; send hostname + capabilities
                conn.write_all(&u32::to_le_bytes(DaemonMessages::HostName as u32))
                    .await?;
                send_string(Pin::new(&mut conn), gethostname::gethostname()).await?;
            }
            _ => {
                eprintln!("unknown greeter control message {msg}")
            }
        }
    }
}

async fn send_string(
    mut stream: Pin<&mut impl AsyncWrite>,
    val: impl AsRef<OsStr>,
) -> std::io::Result<()> {
    let val = val.as_ref();
    stream
        .write_all(&u32::to_le_bytes(val.len() as u32))
        .await?;
    stream.write_all(val.as_bytes()).await?;
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
