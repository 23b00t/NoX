//! nox-screencast-receive (VM): H.264 from dom0 on stdin, offered as a
//! PipeWire video source; prints the node id on stdout once the node exists
//! and runs until the stream ends (then exits 0) or the app leaves.
//!
//! GStreamer only decodes (fdsrc → h264parse → avdec_h264 → videoconvert →
//! BGRx → appsink). The node is a PipeWire stream of its own, driver of its
//! graph (PipeWire allocates the memfd buffers), like the screencast streams of
//! xdg-desktop-portal-wlr: format BGRx, the frame's size, framerate 0/1
//! (variable; Chromium asks for exactly that) with a maxFramerate range.
//! A new frame size renegotiates the format; consumers may come and go.
//!
//! `nox-screencast-receive <node name>`

use std::cell::RefCell;
use std::io::Write;
use std::process::ExitCode;
use std::rc::Rc;
use std::thread;

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use gstreamer_video as gst_video;
use pipewire as pw;
use pw::spa;
use pw::spa::pod::{Object, Pod, Property, Value};
use pw::spa::utils::{Choice, ChoiceEnum, ChoiceFlags, Fraction, Rectangle};

/// One decoded frame, rows packed (stride = width * 4)
struct Frame {
    width: u32,
    height: u32,
    data: Vec<u8>,
}

enum Msg {
    Frame(Frame),
    End,
}

/// What the PipeWire side knows
#[derive(Default)]
struct State {
    /// The newest frame; a consumer that (re)connects gets it right away
    last: Option<Rc<Frame>>,
    /// `last` not yet handed out
    fresh: bool,
    /// The size the format was announced with
    size: Option<(u32, u32)>,
    connected: bool,
    node_printed: bool,
}

fn serialize(obj: Object) -> Vec<u8> {
    spa::pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &Value::Object(obj),
    )
    .expect("pod serializes")
    .0
    .into_inner()
}

fn format_pod(width: u32, height: u32) -> Vec<u8> {
    serialize(spa::pod::object!(
        spa::utils::SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(
            spa::param::format::FormatProperties::MediaType,
            Id,
            spa::param::format::MediaType::Video
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::MediaSubtype,
            Id,
            spa::param::format::MediaSubtype::Raw
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoFormat,
            Id,
            spa::param::video::VideoFormat::BGRx
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoSize,
            Rectangle,
            Rectangle { width, height }
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoFramerate,
            Fraction,
            Fraction { num: 0, denom: 1 }
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoMaxFramerate,
            Choice,
            Range,
            Fraction,
            Fraction { num: 60, denom: 1 },
            Fraction { num: 1, denom: 1 },
            Fraction { num: 60, denom: 1 }
        ),
    ))
}

fn buffers_pod(width: u32, height: u32) -> Vec<u8> {
    let stride = (width * 4) as i32;
    serialize(Object {
        type_: spa::sys::SPA_TYPE_OBJECT_ParamBuffers,
        id: spa::sys::SPA_PARAM_Buffers,
        properties: vec![
            Property::new(
                spa::sys::SPA_PARAM_BUFFERS_buffers,
                Value::Choice(spa::pod::ChoiceValue::Int(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range {
                        default: 4,
                        min: 2,
                        max: 16,
                    },
                ))),
            ),
            Property::new(spa::sys::SPA_PARAM_BUFFERS_blocks, Value::Int(1)),
            Property::new(
                spa::sys::SPA_PARAM_BUFFERS_size,
                Value::Int(stride * height as i32),
            ),
            Property::new(spa::sys::SPA_PARAM_BUFFERS_stride, Value::Int(stride)),
            Property::new(
                spa::sys::SPA_PARAM_BUFFERS_dataType,
                Value::Int(1 << spa::sys::SPA_DATA_MemFd),
            ),
        ],
    })
}

/// Decodes stdin on the GStreamer side and sends frames to the main loop
fn decode(sender: &pw::channel::Sender<Msg>) -> Result<(), String> {
    gst::init().map_err(|e| e.to_string())?;
    let pipeline = gst::parse::launch(
        "fdsrc fd=0 ! h264parse ! avdec_h264 ! videoconvert \
         ! video/x-raw,format=BGRx ! appsink name=sink max-buffers=2 drop=true sync=false",
    )
    .map_err(|e| e.to_string())?
    .downcast::<gst::Pipeline>()
    .map_err(|_| "not a pipeline".to_string())?;
    let sink = pipeline
        .by_name("sink")
        .and_then(|s| s.downcast::<gst_app::AppSink>().ok())
        .ok_or("no appsink")?;
    pipeline
        .set_state(gst::State::Playing)
        .map_err(|e| e.to_string())?;
    while let Ok(sample) = sink.pull_sample() {
        let (Some(caps), Some(buffer)) = (sample.caps(), sample.buffer()) else {
            continue;
        };
        let Ok(info) = gst_video::VideoInfo::from_caps(caps) else {
            continue;
        };
        let Ok(map) = buffer.map_readable() else {
            continue;
        };
        let (width, height) = (info.width(), info.height());
        let row = (width * 4) as usize;
        let stride = info.stride()[0] as usize;
        let offset = info.offset()[0];
        let mut data = Vec::with_capacity(row * height as usize);
        for y in 0..height as usize {
            let start = offset + y * stride;
            match map.get(start..start + row) {
                Some(r) => data.extend_from_slice(r),
                None => break,
            }
        }
        if data.len() != row * height as usize {
            continue;
        }
        if sender
            .send(Msg::Frame(Frame {
                width,
                height,
                data,
            }))
            .is_err()
        {
            break;
        }
    }
    let _ = pipeline.set_state(gst::State::Null);
    Ok(())
}

fn run(name: &str) -> Result<(), pw::Error> {
    pw::init();
    let mainloop = pw::main_loop::MainLoop::new(None)?;
    let context = pw::context::Context::new(&mainloop)?;
    let core = context.connect(None)?;
    let stream = Rc::new(pw::stream::Stream::new(
        &core,
        name,
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Source",
            *pw::keys::MEDIA_CLASS => "Video/Source",
            *pw::keys::NODE_NAME => name,
            *pw::keys::NODE_DESCRIPTION => "dom0",
        },
    )?);
    let state = Rc::new(RefCell::new(State::default()));

    let _listener = stream
        .add_local_listener_with_user_data(state.clone())
        .state_changed(|stream, state, _old, new| {
            let mut s = state.borrow_mut();
            if !s.node_printed
                && matches!(
                    new,
                    pw::stream::StreamState::Paused | pw::stream::StreamState::Streaming
                )
            {
                s.node_printed = true;
                let mut out = std::io::stdout();
                let _ = writeln!(out, "{}", stream.node_id());
                let _ = out.flush();
            }
            let resend = matches!(new, pw::stream::StreamState::Streaming) && s.last.is_some();
            if resend {
                s.fresh = true;
            }
            drop(s);
            if resend {
                let _ = stream.trigger_process();
            }
            if let pw::stream::StreamState::Error(e) = new {
                eprintln!("nox-screencast-receive: stream error: {e}");
            }
        })
        .param_changed(|stream, state, id, param| {
            // The consumer fixed the format: tell it how the buffers look
            if id != spa::param::ParamType::Format.as_raw() || param.is_none() {
                return;
            }
            let Some((w, h)) = state.borrow().size else {
                return;
            };
            let bytes = buffers_pod(w, h);
            if let Some(pod) = Pod::from_bytes(&bytes) {
                let _ = stream.update_params(&mut [pod]);
            }
        })
        .process(|stream, state| {
            let frame = {
                let mut s = state.borrow_mut();
                if !s.fresh {
                    return;
                }
                s.fresh = false;
                match s.last.clone() {
                    Some(f) => f,
                    None => return,
                }
            };
            let Some(mut buffer) = stream.dequeue_buffer() else {
                return;
            };
            let datas = buffer.datas_mut();
            let Some(d) = datas.first_mut() else {
                return;
            };
            let stride = (frame.width * 4) as i32;
            let n = match d.data() {
                Some(slice) => {
                    let n = slice.len().min(frame.data.len());
                    slice[..n].copy_from_slice(&frame.data[..n]);
                    n
                }
                None => 0,
            };
            let chunk = d.chunk_mut();
            *chunk.offset_mut() = 0;
            *chunk.stride_mut() = stride;
            *chunk.size_mut() = n as u32;
        })
        .register()?;

    let (sender, receiver) = pw::channel::channel::<Msg>();
    let loop_ = mainloop.clone();
    let st = stream.clone();
    let state_rx = state.clone();
    let _attached = receiver.attach(mainloop.loop_(), move |msg| match msg {
        Msg::End => loop_.quit(),
        Msg::Frame(frame) => {
            let size = (frame.width, frame.height);
            let mut s = state_rx.borrow_mut();
            let renegotiate = s.size != Some(size);
            s.size = Some(size);
            s.last = Some(Rc::new(frame));
            s.fresh = true;
            let connected = s.connected;
            s.connected = true;
            drop(s);
            if renegotiate {
                let bytes = format_pod(size.0, size.1);
                let Some(pod) = Pod::from_bytes(&bytes) else {
                    return;
                };
                let result = if connected {
                    st.update_params(&mut [pod])
                } else {
                    st.connect(
                        spa::utils::Direction::Output,
                        None,
                        pw::stream::StreamFlags::DRIVER | pw::stream::StreamFlags::MAP_BUFFERS,
                        &mut [pod],
                    )
                };
                if let Err(e) = result {
                    eprintln!("nox-screencast-receive: format: {e}");
                }
            }
            // A consumer that is streaming gets the frame now
            if matches!(st.state(), pw::stream::StreamState::Streaming) {
                let _ = st.trigger_process();
            }
        }
    });

    thread::spawn(move || {
        if let Err(e) = decode(&sender) {
            eprintln!("nox-screencast-receive: decode: {e}");
        }
        let _ = sender.send(Msg::End);
    });
    mainloop.run();
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [name] = args.as_slice() else {
        eprintln!("usage: nox-screencast-receive <node name>");
        return ExitCode::from(2);
    };
    match run(name) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("nox-screencast-receive: {e}");
            ExitCode::FAILURE
        }
    }
}
