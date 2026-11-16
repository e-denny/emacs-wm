// SPDX-License-Identifier: GPL-3.0-or-later
//
// pointerinject: move the pointer, or drag with a modifier held, inside a
// running river session.
//
// Elisp cannot pass the file descriptors these protocols need, so the WM never
// uses them; this is test scaffolding only.  A virtual pointer is attached by
// river as an ordinary pointer device, so its motion produces the same
// `river_seat_v1.op_delta` events a real mouse would.
//
// Usage:
//   pointerinject move DX DY          # relative motion
//   pointerinject drag DX DY [-m MOD] [-b BUTTON] [--steps N] [--hold MS]
//
// `drag` holds MOD, presses BUTTON, moves DX,DY in N steps, releases BUTTON
// and clears the modifier -- i.e. one complete pointer drag, which is what
// starts a move/resize op through a pointer binding.

use std::io::Write;
use std::os::fd::AsFd;

use anyhow::{anyhow, bail, Context, Result};
use wayland_client::protocol::{wl_pointer, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};
use xkbcommon::xkb;

mod river {
    pub extern crate wayland_client;
    pub use wayland_client::protocol::wl_seat;

    mod interfaces {
        pub(super) mod vkb {
            pub use wayland_client::protocol::__interfaces::*;
            pub use wayland_client::protocol::{wl_output, wl_pointer, wl_seat};
            wayland_scanner::generate_interfaces!("protocol/virtual-keyboard-unstable-v1.xml");
        }
        pub(super) mod vptr {
            pub use super::vkb::*;
            pub use wayland_client::protocol::{wl_output, wl_pointer, wl_seat};
            wayland_scanner::generate_interfaces!("protocol/wlr-virtual-pointer-unstable-v1.xml");
        }
    }
    use self::interfaces::vkb::*;
    use self::interfaces::vptr::*;
    wayland_scanner::generate_client_code!("protocol/virtual-keyboard-unstable-v1.xml");
    wayland_scanner::generate_client_code!("protocol/wlr-virtual-pointer-unstable-v1.xml");
}

use river::zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1;
use river::zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1;
use river::zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1;
use river::zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1;

struct State {
    pointer_manager: Option<ZwlrVirtualPointerManagerV1>,
    keyboard_manager: Option<ZwpVirtualKeyboardManagerV1>,
    seat: Option<wl_seat::WlSeat>,
    pointer: Option<ZwlrVirtualPointerV1>,
    keyboard: Option<ZwpVirtualKeyboardV1>,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            match interface.as_str() {
                "wl_seat" => state.seat = Some(registry.bind(name, version.min(9), qh, ())),
                "zwlr_virtual_pointer_manager_v1" => {
                    state.pointer_manager = Some(registry.bind(name, version.min(2), qh, ()))
                }
                "zwp_virtual_keyboard_manager_v1" => {
                    state.keyboard_manager = Some(registry.bind(name, version.min(1), qh, ()))
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}

macro_rules! ignore_events {
    ($($t:ty),*) => {$(
        impl Dispatch<$t, ()> for State {
            fn event(_: &mut Self, _: &$t, _: <$t as wayland_client::Proxy>::Event,
                     _: &(), _: &Connection, _: &QueueHandle<Self>) {}
        }
    )*};
}
ignore_events!(ZwlrVirtualPointerManagerV1, ZwlrVirtualPointerV1,
               ZwpVirtualKeyboardManagerV1, ZwpVirtualKeyboardV1);

fn keymap_fd() -> Result<(std::fs::File, u32)> {
    let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let keymap = xkb::Keymap::new_from_names(
        &ctx, "", "", "", "", None, xkb::KEYMAP_COMPILE_NO_FLAGS,
    )
    .ok_or_else(|| anyhow!("could not build an xkb keymap"))?;
    let text = keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1);
    let path = std::env::temp_dir().join(format!("pointerinject-{}.xkb", std::process::id()));
    let mut file = std::fs::File::create(&path).context("creating keymap file")?;
    file.write_all(text.as_bytes())?;
    file.flush()?;
    let fd = std::fs::File::open(&path)?;
    let _ = std::fs::remove_file(&path);
    Ok((fd, text.len() as u32))
}

fn main() -> Result<()> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mode = argv.first().cloned().unwrap_or_default();
    let mut dx = 0i32;
    let mut dy = 0i32;
    let mut mods = 0u32;
    let mut button = 272u32; // BTN_LEFT
    let mut steps = 8u32;
    let mut hold_ms = 250u64;

    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "-m" | "--mod" => {
                i += 1;
                mods |= match argv.get(i).map(|s| s.to_ascii_lowercase()).as_deref() {
                    Some("shift") => 1,
                    Some("ctrl") | Some("control") => 4,
                    Some("alt") | Some("mod1") => 8,
                    Some("super") | Some("mod4") | Some("logo") => 64,
                    other => bail!("unknown modifier {other:?}"),
                };
            }
            "-b" | "--button" => { i += 1; button = argv.get(i).ok_or_else(|| anyhow!("-b needs a number"))?.parse()?; }
            "--steps" => { i += 1; steps = argv.get(i).ok_or_else(|| anyhow!("--steps needs a number"))?.parse()?; }
            "--hold" => { i += 1; hold_ms = argv.get(i).ok_or_else(|| anyhow!("--hold needs ms"))?.parse()?; }
            other => match other.parse::<i32>() {
                Ok(n) if dx == 0 => dx = n,
                Ok(n) => dy = n,
                Err(_) => bail!("unexpected argument {other:?}"),
            },
        }
        i += 1;
    }

    if mode == "move" && dx == 0 && dy == 0 {
        bail!("move needs a delta: pointerinject move DX DY");
    }
    if mode != "move" && mode != "drag" {
        bail!("usage: pointerinject move DX DY | pointerinject drag DX DY [-m MOD] [-b BTN]");
    }

    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, ());
    let mut state = State {
        pointer_manager: None, keyboard_manager: None,
        seat: None, pointer: None, keyboard: None,
    };
    queue.roundtrip(&mut state)?;

    let seat = state.seat.clone().ok_or_else(|| anyhow!("no wl_seat"))?;
    let pm = state.pointer_manager.clone()
        .ok_or_else(|| anyhow!("river did not advertise zwlr_virtual_pointer_manager_v1"))?;
    let pointer = pm.create_virtual_pointer(Some(&seat), &qh, ());
    state.pointer = Some(pointer.clone());

    // A virtual keyboard only for the modifier state: river matches pointer
    // bindings against the seat's modifiers.
    let mut keyboard = None;
    if mods != 0 {
        let km = state.keyboard_manager.clone()
            .ok_or_else(|| anyhow!("river did not advertise zwp_virtual_keyboard_manager_v1"))?;
        let kbd = km.create_virtual_keyboard(&seat, &qh, ());
        let (fd, size) = keymap_fd()?;
        kbd.keymap(1, fd.as_fd(), size);
        keyboard = Some(kbd);
    }
    queue.roundtrip(&mut state)?;

    let now = || {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u32).unwrap_or(0)
    };

    if let Some(kbd) = &keyboard {
        kbd.modifiers(mods, 0, 0, 0);
        queue.roundtrip(&mut state)?;
    }

    if mode == "drag" {
        pointer.button(now(), button, wl_pointer::ButtonState::Pressed);
        queue.roundtrip(&mut state)?;
        // Give the WM a manage sequence to start the op before motion arrives.
        std::thread::sleep(std::time::Duration::from_millis(hold_ms));
    }

    let (sx, sy) = (dx / steps as i32, dy / steps as i32);
    for n in 0..steps {
        let (mx, my) = if n + 1 == steps {
            (dx - sx * (steps as i32 - 1), dy - sy * (steps as i32 - 1))
        } else {
            (sx, sy)
        };
        pointer.motion(now(), mx as f64, my as f64);
        pointer.frame();
        queue.roundtrip(&mut state)?;
        std::thread::sleep(std::time::Duration::from_millis(30));
    }

    if mode == "drag" {
        pointer.button(now(), button, wl_pointer::ButtonState::Released);
        pointer.frame();
        queue.roundtrip(&mut state)?;
    }

    if let Some(kbd) = &keyboard {
        kbd.modifiers(0, 0, 0, 0);
        queue.roundtrip(&mut state)?;
    }
    conn.flush()?;
    std::thread::sleep(std::time::Duration::from_millis(150));
    eprintln!("pointerinject: {mode} {dx} {dy} mods {mods:#x} button {button} steps {steps}");
    Ok(())
}
