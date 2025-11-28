use std::time::Duration;

use anyhow::{Context, Result, ensure};
use evdev::{EventType, KeyCode};

pub fn start_failsafe() -> Result<impl Future<Output = ()>> {
    //We start immediately after udevd, so it might take a short bit until /dev/input exists
    let mut poll_attempt = 0;
    while !std::fs::exists("/dev/input").context("failed to poll for /dev/input creation")? {
        poll_attempt += 1;
        ensure!(poll_attempt <= 25, "/dev/input does not exist");
        std::thread::sleep(Duration::from_millis(200));
    }

    //Grab all keyboard evdev devices
    let mut devs = Vec::new();
    for (path, dev) in evdev::enumerate() {
        if !dev.supported_events().contains(EventType::KEY)
            && !dev.supported_events().contains(EventType::REPEAT)
        {
            continue;
        }

        //Check if the killswitch has been engaged
        let state = dev
            .get_key_state()
            .with_context(|| format!("failed to fetch evdev {path:?} state"))?;

        ensure!(
            !state.contains(KeyCode::KEY_ESC),
            "fallback killswitch active"
        );

        devs.push(dev);
    }

    //We need to have at least one keyboard to safely proceed
    ensure!(!devs.is_empty(), "no keyboard evdev devices to grab");

    //Poll the keyboard devices in the background to listen for the killswitch command
    let (tx, rx) = smol::channel::bounded::<()>(1);

    std::thread::spawn(move || {
        'failsafe: loop {
            for dev in &mut devs {
                static MODS: &[KeyCode] = &[
                    KeyCode::KEY_LEFTSHIFT,
                    KeyCode::KEY_LEFTCTRL,
                    KeyCode::KEY_RIGHTSHIFT,
                    KeyCode::KEY_RIGHTCTRL,
                ];

                let state = dev.get_key_state().expect("failed to fetch evdev state");
                if MODS.iter().any(|&c| state.contains(c)) && state.contains(KeyCode::KEY_ESC) {
                    break 'failsafe;
                }
            }

            std::thread::sleep(Duration::from_millis(100));
        }

        eprintln!("failsafe killswitch engaged; exiting...");
        _ = tx.send_blocking(());

        std::thread::sleep(Duration::from_secs(3));
        std::process::abort(); // - we didn't exit, something is very wrong
    });

    Ok(async move {
        _ = rx.recv().await;
    })
}
