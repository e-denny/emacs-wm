// SPDX-License-Identifier: GPL-3.0-or-later
//
// screenshot: capture a river output to a PPM file.
//
//   screenshot OUT.ppm [SECONDS-TO-WAIT]
//
// Test scaffolding only: screencopy hands the image over through a file
// descriptor, which is exactly what Emacs Lisp cannot receive, so the WM cannot
// do this.  It exists so borders, positions and stacking can be *seen* rather
// than inferred.  Convert the PPM with `ffmpeg -i out.ppm out.png`.
//
// A compositor may offer several wl_shm formats (river offers XBGR8888 first,
// then the ones we can read), so all `buffer` events are collected and the
// best known format is chosen.

use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsFd;

use anyhow::{anyhow, bail, Context, Result};
use wayland_client::protocol::{wl_buffer, wl_output, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{Connection, Dispatch, QueueHandle};

mod river {
    pub extern crate wayland_client;
    pub use wayland_client::protocol::{wl_buffer, wl_output, wl_shm, wl_shm_pool};

    mod interfaces {
        pub(super) mod screencopy {
            pub use wayland_client::protocol::__interfaces::*;
            pub use wayland_client::protocol::{wl_buffer, wl_output, wl_shm, wl_shm_pool};
            wayland_scanner::generate_interfaces!("protocol/wlr-screencopy-unstable-v1.xml");
        }
    }
    use self::interfaces::screencopy::*;
    wayland_scanner::generate_client_code!("protocol/wlr-screencopy-unstable-v1.xml");
}

use river::zwlr_screencopy_frame_v1::{Event as FrameEvent, ZwlrScreencopyFrameV1};
use river::zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1;

/// One wl_shm format the compositor said it can hand over.
#[derive(Clone, Copy, Debug)]
struct Candidate {
    format: u32,
    width: u32,
    height: u32,
    stride: u32,
}

/// wl_shm format numbers.  ARGB8888 and XRGB8888 are 0/1; the others are DRM
/// fourcc codes, which is why they look like ASCII in the events.
const FMT_ARGB8888: u32 = 0;
const FMT_XRGB8888: u32 = 1;
const FMT_XBGR8888: u32 = 0x3432_4258; // 'X','B','2','4'
const FMT_ABGR8888: u32 = 0x3432_4241; // 'A','B','2','4'

/// Bytes per pixel order, from the low byte of a little-endian word.
fn channel_order(format: u32) -> Option<(usize, usize, usize)> {
    match format {
        FMT_ARGB8888 | FMT_XRGB8888 => Some((2, 1, 0)), // B G R X
        FMT_ABGR8888 | FMT_XBGR8888 => Some((0, 1, 2)), // R G B X
        _ => None,
    }
}

fn format_name(format: u32) -> String {
    match format {
        FMT_ARGB8888 => "ARGB8888".into(),
        FMT_XRGB8888 => "XRGB8888".into(),
        FMT_XBGR8888 => "XBGR8888".into(),
        FMT_ABGR8888 => "ABGR8888".into(),
        other => format!("0x{other:08x}"),
    }
}

struct State {
    manager: Option<ZwlrScreencopyManagerV1>,
    shm: Option<wl_shm::WlShm>,
    output: Option<wl_output::WlOutput>,
    frame: Option<ZwlrScreencopyFrameV1>,
    candidates: Vec<Candidate>,
    ready: bool,
    failed: Option<String>,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(state: &mut Self, registry: &wl_registry::WlRegistry, event: wl_registry::Event,
             _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            match interface.as_str() {
                "wl_shm" => state.shm = Some(registry.bind(name, version.min(1), qh, ())),
                "wl_output" if state.output.is_none() => {
                    state.output = Some(registry.bind(name, version.min(4), qh, ()))
                }
                "zwlr_screencopy_manager_v1" => {
                    state.manager = Some(registry.bind(name, version.min(3), qh, ()))
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
impl Dispatch<wl_buffer::WlBuffer, ()> for State {
    fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrScreencopyManagerV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrScreencopyManagerV1,
             _: <ZwlrScreencopyManagerV1 as wayland_client::Proxy>::Event, _: &(), _: &Connection,
             _: &QueueHandle<Self>) {}
}

impl Dispatch<ZwlrScreencopyFrameV1, ()> for State {
    fn event(state: &mut Self, _frame: &ZwlrScreencopyFrameV1, event: FrameEvent, _: &(),
             _: &Connection, _: &QueueHandle<Self>) {
        match event {
            FrameEvent::Buffer { format, width, height, stride } => {
                let format = match format {
                    wayland_client::WEnum::Value(f) => f as u32,
                    wayland_client::WEnum::Unknown(n) => n,
                };
                state.candidates.push(Candidate { format, width, height, stride });
            }
            FrameEvent::Ready { .. } => state.ready = true,
            FrameEvent::Failed => state.failed = Some("compositor refused the capture".into()),
            _ => {}
        }
    }
}

fn main() -> Result<()> {
    let path = std::env::args().nth(1).unwrap_or_else(|| "shot.ppm".into());
    let wait: u64 = std::env::args().nth(2).map(|s| s.parse().unwrap_or(5)).unwrap_or(5);

    let conn = Connection::connect_to_env().context("connecting to Wayland")?;
    let mut queue = conn.new_event_queue();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, ());
    let mut state = State {
        manager: None, shm: None, output: None, frame: None,
        candidates: Vec::new(), ready: false, failed: None,
    };
    queue.roundtrip(&mut state)?;

    let manager = state.manager.clone().ok_or_else(|| anyhow!("no zwlr_screencopy_manager_v1"))?;
    let output = state.output.clone().ok_or_else(|| anyhow!("no wl_output"))?;
    let shm = state.shm.clone().ok_or_else(|| anyhow!("no wl_shm"))?;

    let frame = manager.capture_output(0, &output, &qh, ());
    state.frame = Some(frame.clone());
    queue.roundtrip(&mut state)?;

    if state.candidates.is_empty() {
        bail!("no shm buffer offered (only dmabuf?)");
    }
    // Prefer the two formats whose byte order we know best.
    let pick = state.candidates.iter().copied()
        .find(|c| c.format == FMT_XRGB8888 || c.format == FMT_ARGB8888)
        .or_else(|| state.candidates.iter().copied().find(|c| channel_order(c.format).is_some()));
    let Some(cand) = pick else {
        bail!("no usable shm format among {:?}",
              state.candidates.iter().map(|c| format_name(c.format)).collect::<Vec<_>>());
    };
    let Candidate { format, width: w, height: h, stride } = cand;
    let size = (stride as u64) * (h as u64);

    let shm_path = std::env::temp_dir().join(format!("screenshot-{}.shm", std::process::id()));
    let f = std::fs::File::create(&shm_path)?;
    f.set_len(size)?;
    drop(f);
    let fd = std::fs::OpenOptions::new().read(true).write(true).open(&shm_path)?;
    let pool = shm.create_pool(fd.as_fd(), size as i32, &qh, ());
    let buffer = pool.create_buffer(
        0, w as i32, h as i32, stride as i32,
        wl_shm::Format::try_from(format).unwrap_or(wl_shm::Format::Xrgb8888),
        &qh, (),
    );
    frame.copy(&buffer);
    queue.roundtrip(&mut state)?;

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(wait);
    while !state.ready && state.failed.is_none() && std::time::Instant::now() < deadline {
        queue.roundtrip(&mut state)?;
    }
    if let Some(err) = &state.failed {
        bail!("capture failed: {err}");
    }
    if !state.ready {
        bail!("timed out waiting for the capture");
    }

    let mut file = std::fs::OpenOptions::new().read(true).open(&shm_path)?;
    file.seek(SeekFrom::Start(0))?;
    let mut data = vec![0u8; size as usize];
    file.read_exact(&mut data)?;
    let _ = std::fs::remove_file(&shm_path);

    let (ri, gi, bi) = channel_order(format).unwrap_or((2, 1, 0));
    let mut out = std::fs::File::create(&path).context("creating the output file")?;
    write!(out, "P6\n{w} {h}\n255\n")?;
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            let i = (y * stride) as usize + (x * 4) as usize;
            rgb.extend_from_slice(&[data[i + ri], data[i + gi], data[i + bi]]);
        }
    }
    out.write_all(&rgb)?;
    out.flush()?;
    eprintln!("screenshot: {w}x{h} {} -> {path}", format_name(format));
    Ok(())
}
