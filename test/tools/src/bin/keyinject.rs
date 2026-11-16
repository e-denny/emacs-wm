// SPDX-License-Identifier: GPL-3.0-or-later
//
// keyinject: type keys into a running river session as a *real input device*.
//
// This exists only to test emacs-wm.  The window manager's own injection goes
// through river_virtual_keyboard_v1 (synced with the manage sequence) and
// deliberately bypasses binding matching.  A virtual keyboard created directly
// through zwp_virtual_keyboard_manager_v1 is attached by river as an ordinary
// input device instead, so its keys travel the same path as a physical
// keyboard: KeyboardGroup -> river's WM bindings -> river_xkb_binding_v1.pressed
// -> emacs-wm-be -> emacs-wm.  That is the piece no test has covered yet.
//
// Usage:
//   keyinject [-m MOD]... KEY...
//     MOD:  shift | ctrl | alt | super | mod1 | mod4
//     KEY:  an xkb keysym name, e.g. 1 a Return F11
//   keyinject -c CODE [-m MOD]      raw evdev keycode (linux/input-event-codes.h)
//
// Examples:
//   keyinject -m super 1            # what s-1 does
//   keyinject -m super a            # plain letter with a modifier
//   keyinject Return
//
// It sends the keymap (an fd, which is why this cannot be Emacs Lisp), then
// modifiers/key/key/modifiers for each key, and exits.

use std::io::Write;
use std::os::fd::AsFd;

use anyhow::{anyhow, bail, Context, Result};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};
use xkbcommon::xkb;

mod river {
    pub extern crate wayland_client;
    pub use wayland_client::protocol::wl_seat;

    mod interfaces {
        pub(super) mod upstream {
            pub use wayland_client::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/virtual-keyboard-unstable-v1.xml");
        }
    }
    use self::interfaces::upstream::*;
    wayland_scanner::generate_client_code!("protocol/virtual-keyboard-unstable-v1.xml");
}

use river::zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1;
use river::zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1;

const MOD_SHIFT: u32 = 1;
const MOD_CTRL: u32 = 4;
const MOD_ALT: u32 = 8;
const MOD_SUPER: u32 = 64;

struct Keymap {
    inner: xkb::Keymap,
    file: std::fs::File,
    size: u32,
}

struct State {
    manager: Option<ZwpVirtualKeyboardManagerV1>,
    seat: Option<wl_seat::WlSeat>,
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
                "wl_seat" => {
                    let seat: wl_seat::WlSeat = registry.bind(name, version.min(9), qh, ());
                    state.seat = Some(seat);
                }
                "zwp_virtual_keyboard_manager_v1" => {
                    let mgr = registry.bind(name, version.min(1), qh, ());
                    state.manager = Some(mgr);
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        _: &mut Self,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpVirtualKeyboardManagerV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ZwpVirtualKeyboardManagerV1,
        _: <ZwpVirtualKeyboardManagerV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpVirtualKeyboardV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ZwpVirtualKeyboardV1,
        _: <ZwpVirtualKeyboardV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

fn build_keymap() -> Result<Keymap> {
    let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let keymap = xkb::Keymap::new_from_names(
        &ctx, "", "", "", "", None, xkb::KEYMAP_COMPILE_NO_FLAGS,
    )
    .ok_or_else(|| anyhow!("could not build an xkb keymap from the default RMLVO"))?;
    let text = keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1);
    let size = text.len() as u32;
    let path = std::env::temp_dir().join(format!("keyinject-{}.xkb", std::process::id()));
    let mut file = std::fs::File::create(&path).context("creating keymap file")?;
    file.write_all(text.as_bytes())?;
    file.flush()?;
    let file = std::fs::File::open(&path)?;
    let _ = std::fs::remove_file(&path);
    Ok(Keymap { inner: keymap, file, size })
}

fn keysym_for(name: &str) -> u32 {
    let sym = xkb::keysym_from_name(name, xkb::KEYSYM_CASE_INSENSITIVE);
    u32::from(sym)
}

/// keysym -> evdev keycode (xkb keycodes are offset by 8).
fn keycode_for(keymap: &xkb::Keymap, keysym: u32, shift: bool) -> Option<u32> {
    let sym = xkb::Keysym::from(keysym);
    for kc in keymap.min_keycode().raw()..=keymap.max_keycode().raw() {
        let kc = xkb::Keycode::new(kc);
        for (level, needs_shift) in [(0u32, false), (1u32, true)] {
            if !shift || needs_shift || level == 0 {
                let syms = keymap.key_get_syms_by_level(kc, 0, level);
                if syms.contains(&sym) {
                    return Some(kc.raw().checked_sub(8)?);
                }
            }
        }
    }
    None
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1).peekable();
    let mut mods = 0u32;
    let mut keysyms: Vec<u32> = Vec::new();
    let mut codes: Vec<u32> = Vec::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-m" | "--mod" => {
                let name = args.next().ok_or_else(|| anyhow!("-m needs a modifier"))?;
                mods |= match name.to_ascii_lowercase().as_str() {
                    "shift" => MOD_SHIFT,
                    "ctrl" | "control" => MOD_CTRL,
                    "alt" | "mod1" => MOD_ALT,
                    "super" | "mod4" | "logo" => MOD_SUPER,
                    other => bail!("unknown modifier {other}"),
                };
            }
            "-c" | "--code" => {
                let code = args
                    .next()
                    .ok_or_else(|| anyhow!("-c needs an evdev keycode"))?
                    .parse::<u32>()?;
                codes.push(code);
            }
            other => keysyms.push(keysym_for(other)),
        }
    }
    if keysyms.is_empty() && codes.is_empty() {
        bail!("nothing to type: pass keysym names or -c CODE");
    }

    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, ());
    let mut state = State { manager: None, seat: None, keyboard: None };
    queue.roundtrip(&mut state)?;

    let (manager, seat) = match (state.manager.clone(), state.seat.clone()) {
        (Some(m), Some(s)) => (m, s),
        _ => bail!("river did not advertise zwp_virtual_keyboard_manager_v1 and wl_seat"),
    };
    let keyboard = manager.create_virtual_keyboard(&seat, &qh, ());
    queue.roundtrip(&mut state)?;

    let keymap = build_keymap()?;
    // 1 == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
    keyboard.keymap(1, keymap.file.as_fd(), keymap.size);
    queue.roundtrip(&mut state)?;

    let mut resolved: Vec<(u32, bool)> = Vec::new();
    for sym in &keysyms {
        let (code, shift) = match keycode_for(&keymap.inner, *sym, false) {
            Some(code) => (code, false),
            None => match keycode_for(&keymap.inner, *sym, true) {
                Some(code) => (code, true),
                None => bail!("cannot map keysym {sym:#x} to a keycode"),
            },
        };
        resolved.push((code, shift));
    }
    resolved.extend(codes.iter().map(|c| (*c, false)));

    for (code, shift) in resolved {
        let mods = mods | if shift { MOD_SHIFT } else { 0 };
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u32)
            .unwrap_or(0);
        if mods != 0 {
            keyboard.modifiers(mods, 0, 0, 0);
        } else {
            keyboard.modifiers(0, 0, 0, 0);
        }
        keyboard.key(t, code, 1);
        keyboard.key(t + 1, code, 0);
        if mods != 0 {
            keyboard.modifiers(0, 0, 0, 0);
        }
        eprintln!("keyinject: keycode {code} mods {mods:#x}");
    }
    queue.roundtrip(&mut state)?;
    conn.flush()?;
    // Give river a moment to route the events before the socket disappears.
    std::thread::sleep(std::time::Duration::from_millis(120));
    Ok(())
}
