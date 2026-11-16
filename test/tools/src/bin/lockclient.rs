// SPDX-License-Identifier: GPL-3.0-or-later
//
// lockclient: take an ext-session-lock lock and paint every output solid.
//
//   lockclient [SECONDS] [COLOUR-RRGGBB]
//
// Test scaffolding only (the WM does not draw lock surfaces; river and the
// lock client do).  It exists so the WM's session-lock behaviour -- no focus
// changes, no injected keys, no ordinary bindings -- can be observed.
// Exits after SECONDS (default 8) or on SIGTERM, which releases the lock.

use std::io::Write;
use std::os::fd::AsFd;

use anyhow::{anyhow, bail, Context, Result};
use wayland_client::protocol::{wl_buffer, wl_compositor, wl_output, wl_registry, wl_shm,
                               wl_shm_pool, wl_surface};
use wayland_client::{Connection, Dispatch, QueueHandle};

mod river {
    pub extern crate wayland_client;
    pub use wayland_client::protocol::{wl_compositor, wl_output, wl_shm, wl_shm_pool, wl_surface};

    mod interfaces {
        pub(super) mod lock {
            pub use wayland_client::protocol::__interfaces::*;
            pub use wayland_client::protocol::{wl_output, wl_shm, wl_surface};
            wayland_scanner::generate_interfaces!("protocol/ext-session-lock-v1.xml");
        }
    }
    use self::interfaces::lock::*;
    wayland_scanner::generate_client_code!("protocol/ext-session-lock-v1.xml");
}

use river::ext_session_lock_manager_v1::ExtSessionLockManagerV1;
use river::ext_session_lock_surface_v1::{Event as LockSurfaceEvent, ExtSessionLockSurfaceV1};
use river::ext_session_lock_v1::{Event as LockEvent, ExtSessionLockV1};

struct State {
    manager: Option<ExtSessionLockManagerV1>,
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    outputs: Vec<wl_output::WlOutput>,
    lock: Option<ExtSessionLockV1>,
    locked: bool,
    finished: bool,
    color: (u8, u8, u8),
    surfaces: Vec<(ExtSessionLockSurfaceV1, wl_surface::WlSurface, u32, u32)>,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(state: &mut Self, registry: &wl_registry::WlRegistry, event: wl_registry::Event,
             _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            match interface.as_str() {
                "wl_shm" => state.shm = Some(registry.bind(name, version.min(1), qh, ())),
                "wl_compositor" => {
                    state.compositor = Some(registry.bind(name, version.min(4), qh, ()))
                }
                "wl_output" => state.outputs.push(registry.bind(name, version.min(4), qh, ())),
                "ext_session_lock_manager_v1" => {
                    state.manager = Some(registry.bind(name, version.min(1), qh, ()))
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_output::WlOutput, ()> for State {
    fn event(_: &mut Self, _: &wl_output::WlOutput, _: wl_output::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_shm::WlShm, ()> for State {
    fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_shm_pool::WlShmPool, ()> for State {
    fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_surface::WlSurface, ()> for State {
    fn event(_: &mut Self, _: &wl_surface::WlSurface, _: wl_surface::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_compositor::WlCompositor, ()> for State {
    fn event(_: &mut Self, _: &wl_compositor::WlCompositor, _: wl_compositor::Event,
             _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_buffer::WlBuffer, ()> for State {
    fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<ExtSessionLockManagerV1, ()> for State {
    fn event(_: &mut Self, _: &ExtSessionLockManagerV1,
             _: <ExtSessionLockManagerV1 as wayland_client::Proxy>::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<ExtSessionLockSurfaceV1, ()> for State {
    fn event(state: &mut Self, surface: &ExtSessionLockSurfaceV1, event: LockSurfaceEvent,
             _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let LockSurfaceEvent::Configure { serial, width, height } = event {
            // The protocol requires ack_configure before the first buffer
            // commit, or the compositor raises commit_before_first_ack.
            surface.ack_configure(serial);
            if let Some(entry) = state.surfaces.iter_mut().find(|e| &e.0 == surface) {
                entry.2 = width;
                entry.3 = height;
            }
            paint(state, qh, surface);
        }
    }
}
impl Dispatch<ExtSessionLockV1, ()> for State {
    fn event(state: &mut Self, _lock: &ExtSessionLockV1, event: LockEvent, _: &(),
             _: &Connection, _: &QueueHandle<Self>) {
        match event {
            LockEvent::Locked => {
                state.locked = true;
                eprintln!("lockclient: locked");
            }
            LockEvent::Finished => {
                state.finished = true;
                eprintln!("lockclient: compositor finished the lock");
            }
        }
    }
}

/// Attach a solid-colour buffer sized to the surface and commit it.
fn paint(state: &mut State, qh: &QueueHandle<State>, lock_surface: &ExtSessionLockSurfaceV1) {
    let Some((_, wl_surface, w, h)) = state
        .surfaces
        .iter()
        .find(|e| &e.0 == lock_surface)
        .cloned()
    else { return };
    let (Some(shm), w, h) = (state.shm.clone(), w, h) else { return };
    if w == 0 || h == 0 {
        return;
    }
    let stride = (w * 4) as i32;
    let size = (stride as u64) * (h as u64);
    let path = std::env::temp_dir().join(format!("lockclient-{}.shm", std::process::id()));
    let (cr, cg, cb) = state.color;
    let mut file = match std::fs::File::create(&path) {
        Ok(f) => f,
        Err(e) => { eprintln!("lockclient: {e}"); return; }
    };
    if file.set_len(size).is_err() {
        return;
    }
    // XRGB8888, little endian: B, G, R, X
    let mut line = Vec::with_capacity((w * 4) as usize);
    for _ in 0..w {
        line.extend_from_slice(&[cb, cg, cr, 0]);
    }
    for _ in 0..h {
        if file.write_all(&line).is_err() {
            return;
        }
    }
    let _ = file.flush();
    let Ok(fd) = std::fs::OpenOptions::new().read(true).write(true).open(&path) else { return };
    let _ = std::fs::remove_file(&path);
    let pool = shm.create_pool(fd.as_fd(), size as i32, qh, ());
    let buffer = pool.create_buffer(0, w as i32, h as i32, stride,
                                    wl_shm::Format::Xrgb8888, qh, ());
    wl_surface.attach(Some(&buffer), 0, 0);
    wl_surface.damage(0, 0, w as i32, h as i32);
    wl_surface.commit();
}

fn main() -> Result<()> {
    let secs: u64 = std::env::args().nth(1).map(|s| s.parse().unwrap_or(8)).unwrap_or(8);
    let colour = std::env::args().nth(2).unwrap_or_else(|| "202020".into());
    let parse = |i: usize| u8::from_str_radix(&colour[i..i + 2], 16).unwrap_or(0x20);
    let color = (parse(0), parse(2), parse(4));

    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, ());
    let mut state = State {
        manager: None, compositor: None, shm: None, outputs: Vec::new(), lock: None,
        locked: false, finished: false, color, surfaces: Vec::new(),
    };
    queue.roundtrip(&mut state)?;

    let manager = state.manager.clone()
        .ok_or_else(|| anyhow!("river did not advertise ext_session_lock_manager_v1"))?;
    if state.outputs.is_empty() {
        bail!("no wl_output");
    }
    let lock = manager.lock(&qh, ());
    state.lock = Some(lock.clone());
    queue.roundtrip(&mut state)?;

    // One lock surface per output.
    let compositor = state.compositor.clone()
        .ok_or_else(|| anyhow!("no wl_compositor"))?;
    let outputs = state.outputs.clone();
    for output in outputs {
        let surface = compositor.create_surface(&qh, ());
        let lock_surface = lock.get_lock_surface(&surface, &output, &qh, ());
        state.surfaces.push((lock_surface, surface, 0, 0));
    }
    queue.roundtrip(&mut state)?;

    // Wait for the compositor to confirm the lock *before* starting the hold.
    // River only sends `locked' once a lock surface or a blank frame has been
    // presented, and a nested session whose host is briefly busy can take
    // longer than a couple of hundred milliseconds over that.  Counting the
    // hold from the confirmation keeps the scenario's timing deterministic;
    // giving up after WAIT_LOCKED is what keeps a stuck compositor from
    // hanging the test.
    const WAIT_LOCKED: u64 = 6;
    let wait_deadline = std::time::Instant::now() + std::time::Duration::from_secs(WAIT_LOCKED);
    while !state.locked && !state.finished && std::time::Instant::now() < wait_deadline {
        queue.roundtrip(&mut state)?;
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    if !state.locked && !state.finished {
        eprintln!("lockclient: no locked event within {WAIT_LOCKED}s");
    }

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
    while state.locked && !state.finished && std::time::Instant::now() < deadline {
        queue.roundtrip(&mut state)?;
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    // Releasing: `unlock_and_destroy' is only legal once the compositor has
    // sent `locked'.  A compositor that never got to present lock surfaces or a
    // blank frame (a nested session whose host stops presenting frames can do
    // this) never sends it, and then plain `destroy' is the required request --
    // `unlock' there is an invalid_unlock protocol error, which kills us and
    // leaves the WM watching a client that "failed to lock".
    match state.lock.take() {
        Some(lock) if state.locked => lock.unlock_and_destroy(),
        Some(lock) => {
            eprintln!("lockclient: compositor never sent locked, destroying the lock");
            lock.destroy();
        }
        None => {}
    }
    let _ = conn.flush();
    // Wait for river to answer before exiting.  Exiting right after the flush
    // races the compositor: the socket can be closed before the request is
    // processed, which leaves the session locked with no client able to
    // unlock it.  A roundtrip guarantees it was read and handled.
    queue.roundtrip(&mut state)?;
    eprintln!("lockclient: released");
    Ok(())
}
