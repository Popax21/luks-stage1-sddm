use std::{collections::HashSet, time::Duration};

use anyhow::{Context, Result, ensure};
use evdev::{EventType, KeyCode};

static MODS: &[KeyCode] = &[
    KeyCode::KEY_LEFTSHIFT,
    KeyCode::KEY_LEFTCTRL,
    KeyCode::KEY_RIGHTSHIFT,
    KeyCode::KEY_RIGHTCTRL,
];

pub fn start_failsafe() -> Result<impl Future<Output = ()>> {
    //We start immediately after udevd, so it might take a short bit until /dev/input exists
    let mut poll_attempt = 0;
    while !std::fs::exists("/dev/input").context("failed to poll for /dev/input creation")? {
        poll_attempt += 1;
        ensure!(poll_attempt <= 25, "/dev/input does not exist");
        std::thread::sleep(Duration::from_millis(200));
    }

    //Check if the killswitch has been engaged before starting
    let mut dev_ids = HashSet::new();
    for dev in enumerate_keyboards() {
        let state = dev.get_key_state().context("failed to fetch evdev state")?;

        println!(
            "using evdev {} for failsafe killswitch",
            dev.name().or(dev.physical_path()).unwrap_or("<unknown>")
        );

        ensure!(
            !state.contains(KeyCode::KEY_ESC),
            "fallback killswitch active"
        );

        dev_ids.insert(dev.input_id());
    }

    //We need to have at least one keyboard to safely proceed
    ensure!(!dev_ids.is_empty(), "no keyboard evdev devices available");

    //Poll the keyboard devices in the background to listen for the killswitch command
    let (tx, rx) = smol::channel::bounded::<()>(1);

    std::thread::spawn(move || {
        'failsafe: loop {
            //Check if the failsafe was engaged after startup
            for dev in enumerate_keyboards() {
                let state = dev.get_key_state().expect("failed to fetch evdev state");

                if dev_ids.insert(dev.input_id()) {
                    // - new device
                    println!(
                        "using evdev {} for failsafe killswitch",
                        dev.name().or(dev.physical_path()).unwrap_or("<unknown>")
                    );

                    if state.contains(KeyCode::KEY_ESC) {
                        break 'failsafe;
                    }
                } else {
                    // - existing device
                    if state.contains(KeyCode::KEY_ESC) && MODS.iter().any(|&c| state.contains(c)) {
                        break 'failsafe;
                    }
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

fn enumerate_keyboards() -> impl Iterator<Item = evdev::Device> {
    evdev::enumerate().map(|(_, d)| d).filter(|dev| {
        dev.supported_events().contains(EventType::KEY)
            && dev.supported_events().contains(EventType::REPEAT)
            && dev.supported_keys().is_some_and(|k| {
                k.contains(KeyCode::KEY_ESC) && MODS.iter().any(|&m| k.contains(m))
            })
    })
}
