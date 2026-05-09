use std::process::Command;

fn main() {
    //Check for pending handoff data
    let Some(handoff) =
        luks_stage1_hibernation_handoff::take().expect("failed to take hibernation handoff data")
    else {
        return;
    };

    if !handoff.is_fresh() {
        println!("ignoring stale hibernation handoff data");
        return;
    }

    let user = handoff.user;
    println!("processing stage-1 SDDM post-hibernation resume handoff for user {user:?}");

    //Query the user's running logind sessions
    let output = Command::new("loginctl")
        .arg("show-user")
        .arg(&user)
        .arg("--property=Sessions")
        .arg("--value")
        .output()
        .expect("failed to invoke loginctl");

    if !output.status.success() {
        eprintln!(
            "failed to query active sessions of user {user:?}: loginctl exited with {}",
            output.status
        );
        std::io::copy(&mut output.stderr.as_slice(), &mut std::io::stderr()).unwrap();

        return;
    }

    //Unlock all user sessions (this clears any screen lockers / etc. which would request a redundant password entry)
    for session in std::str::from_utf8(&output.stdout)
        .expect("malformed loginctl show-user output")
        .split_whitespace()
    {
        //Ensure the session can be unlocked
        let output = Command::new("loginctl")
            .arg("show-session")
            .arg(session)
            .arg("--property=Class")
            .arg("--value")
            .output()
            .expect("failed to invoke loginctl");

        if !output.status.success() {
            eprintln!(
                "failed to check session {session} class of user {user:?}: loginctl exited with {}",
                output.status
            );
            std::io::copy(&mut output.stderr.as_slice(), &mut std::io::stderr()).unwrap();

            continue;
        }

        let class = std::str::from_utf8(&output.stdout)
            .expect("malformed loginctl show-session output")
            .trim();

        if !matches!(class, "user" | "user-light") {
            continue;
        }

        //Unlock the session
        println!("unlocking session {session} for user {user:?} after hibernation resume");

        let status = Command::new("loginctl")
            .arg("unlock-session")
            .arg(session)
            .status()
            .expect("failed to invoke loginctl");

        if !status.success() {
            eprintln!(
                "failed to unlock session {session} for user {user:?}: loginctl exited with {status}"
            );
        }
    }
}
