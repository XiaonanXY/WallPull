use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
pub const CANCELLED_ERR: &str = "__CANCELLED__";

#[derive(Debug, Clone, Copy, Default)]
pub struct FfmpegProgressTick {
    pub out_time_secs: f64,
    pub total_size_bytes: Option<i64>,
    pub speed_factor: Option<f64>,
}

pub fn remove_file_with_retry(path: &Path) {
    for attempt in 0..6 {
        if !path.exists() {
            return;
        }
        if fs::remove_file(path).is_ok() {
            return;
        }
        if attempt < 5 {
            std::thread::sleep(Duration::from_millis(35));
        }
    }
}

fn parse_out_time_hms(raw: &str) -> Option<f64> {
    let mut parts = raw.trim().split(':');
    let h: f64 = parts.next()?.parse().ok()?;
    let m: f64 = parts.next()?.parse().ok()?;
    let s: f64 = parts.next()?.parse().ok()?;
    Some((h * 3600.0 + m * 60.0 + s).max(0.0))
}

pub fn run_ffmpeg_progress<F>(
    program: &Path,
    args: &[OsString],
    current_dir: Option<&Path>,
    timeout: Duration,
    cancel: Option<&AtomicBool>,
    mut on_tick: F,
) -> Result<bool, String>
where
    F: FnMut(FfmpegProgressTick),
{
    let tool_name = program
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("ffmpeg")
        .to_string();
    let mut full_args = Vec::with_capacity(args.len() + 3);
    full_args.push(OsString::from("-nostats"));
    full_args.push(OsString::from("-progress"));
    full_args.push(OsString::from("pipe:1"));
    full_args.extend(args.iter().cloned());

    let mut cmd = Command::new(program);
    cmd.creation_flags(CREATE_NO_WINDOW)
        .args(&full_args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(dir) = current_dir {
        cmd.current_dir(dir);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("启动 {tool_name} 失败：{e}"))?;

    let stdout_pipe = child.stdout.take();
    let (tx, rx) = mpsc::channel::<FfmpegProgressTick>();
    let reader_thread = std::thread::spawn(move || {
        let Some(pipe) = stdout_pipe else {
            return;
        };
        let reader = BufReader::new(pipe);
        let mut current = FfmpegProgressTick::default();
        for line_res in reader.lines() {
            let Ok(line) = line_res else {
                break;
            };
            let trimmed = line.trim();
            if let Some((key, val)) = trimmed.split_once('=') {
                match key {
                    "out_time_us" => {
                        if let Ok(us) = val.trim().parse::<f64>() {
                            current.out_time_secs = (us / 1_000_000.0).max(0.0);
                        }
                    }
                    "out_time_ms" if current.out_time_secs <= 0.0 => {
                        if let Ok(us) = val.trim().parse::<f64>() {
                            current.out_time_secs = (us / 1_000_000.0).max(0.0);
                        }
                    }
                    "out_time" if current.out_time_secs <= 0.0 => {
                        if let Some(secs) = parse_out_time_hms(val) {
                            current.out_time_secs = secs;
                        }
                    }
                    "total_size" => {
                        if let Ok(sz) = val.trim().parse::<i64>() {
                            if sz > 0 {
                                current.total_size_bytes = Some(sz);
                            }
                        }
                    }
                    "speed" => {
                        let s = val.trim().trim_end_matches('x');
                        if let Ok(sp) = s.parse::<f64>() {
                            if sp > 0.0 {
                                current.speed_factor = Some(sp);
                            }
                        }
                    }
                    "progress" => {
                        let _ = tx.send(current);
                        if val.trim() == "end" {
                            break;
                        }
                    }
                    _ => {}
                }
            }
        }
    });

    let start = Instant::now();
    let mut last_emit = Instant::now() - Duration::from_secs(1);
    let mut latest_tick: Option<FfmpegProgressTick> = None;

    let status = loop {
        while let Ok(t) = rx.try_recv() {
            latest_tick = Some(t);
        }
        if let Some(tick) = latest_tick {
            if last_emit.elapsed() >= Duration::from_millis(75) {
                on_tick(tick);
                latest_tick = None;
                last_emit = Instant::now();
            }
        }

        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader_thread.join();
            return Err(CANCELLED_ERR.to_string());
        }
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = reader_thread.join();
                    return Err(format!("{tool_name} 执行超时。"));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = reader_thread.join();
                return Err(format!("等待 {tool_name} 失败：{e}"));
            }
        }
    };

    let _ = reader_thread.join();
    while let Ok(t) = rx.try_recv() {
        latest_tick = Some(t);
    }
    if let Some(tick) = latest_tick {
        on_tick(tick);
    }
    Ok(status.success())
}

pub fn os_args<I, S>(items: I) -> Vec<OsString>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    items
        .into_iter()
        .map(|s| s.as_ref().to_os_string())
        .collect()
}

pub fn run_status(
    program: &Path,
    args: &[OsString],
    current_dir: Option<&Path>,
    timeout: Duration,
    cancel: Option<&AtomicBool>,
) -> Result<bool, String> {
    let tool_name = program
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("外部工具")
        .to_string();
    let mut cmd = Command::new(program);
    cmd.creation_flags(CREATE_NO_WINDOW)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(dir) = current_dir {
        cmd.current_dir(dir);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("启动 {tool_name} 失败：{e}"))?;

    let start = Instant::now();
    loop {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            let _ = child.kill();
            let _ = child.wait();
            return Err("操作已取消。".to_string());
        }
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status.success()),
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("{tool_name} 执行超时。"));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("等待 {tool_name} 失败：{e}"));
            }
        }
    }
}

pub fn run_output(
    program: &Path,
    args: &[OsString],
    current_dir: Option<&Path>,
    timeout: Duration,
    cancel: Option<&AtomicBool>,
) -> Result<Output, String> {
    let tool_name = program
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("外部工具")
        .to_string();
    let mut cmd = Command::new(program);
    cmd.creation_flags(CREATE_NO_WINDOW)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = current_dir {
        cmd.current_dir(dir);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("启动 {tool_name} 失败：{e}"))?;

    let stdout_pipe = child.stdout.take();
    let stderr_pipe = child.stderr.take();

    let out_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(mut r) = stdout_pipe {
            let _ = r.read_to_end(&mut buf);
        }
        buf
    });
    let err_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(mut r) = stderr_pipe {
            let _ = r.read_to_end(&mut buf);
        }
        buf
    });

    let start = Instant::now();
    let status = loop {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = out_thread.join();
            let _ = err_thread.join();
            return Err("操作已取消。".to_string());
        }
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = out_thread.join();
                    let _ = err_thread.join();
                    return Err(format!("{tool_name} 执行超时。"));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = out_thread.join();
                let _ = err_thread.join();
                return Err(format!("等待 {tool_name} 失败：{e}"));
            }
        }
    };

    let stdout = out_thread.join().unwrap_or_default();
    let stderr = err_thread.join().unwrap_or_default();
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}
