#![cfg_attr(not(test), windows_subsystem = "windows")]

mod actions;
mod bridge;
mod clipboard;
mod duplicates;
mod localsend;
mod media;
mod models;
mod pkg;
mod process_runner;
mod scanner;
mod scene_studio;
mod settings;
mod tex;
mod tray;
mod we_bridge;
mod window;

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::Instant;
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};

fn run_bench_studio(target: &str) -> Result<(), String> {
    let input = PathBuf::from(target);
    let scene_pkg = if input.is_dir() {
        input.join("scene.pkg")
    } else {
        input
    };
    if !scene_pkg.is_file() {
        return Err(format!("找不到 scene.pkg：{}", scene_pkg.display()));
    }

    let t0 = Instant::now();
    let session = scene_studio::open_studio_session(&scene_pkg)
        .ok_or_else(|| "open_studio_session 返回 None".to_string())?;
    let open_ms = t0.elapsed().as_millis();

    let default_set: HashSet<usize> = session
        .manifest
        .layers
        .iter()
        .filter(|l| l.default_visible)
        .map(|l| l.index)
        .collect();
    let tmp_dir = std::env::temp_dir();
    let p1 = tmp_dir.join(format!("wallpull_bench_1_{}.png", std::process::id()));
    let p2 = tmp_dir.join(format!("wallpull_bench_2_{}.png", std::process::id()));

    let t1 = Instant::now();
    let r1 = session.render_subset_to_png(&p1, &default_set, 1920, true, false)?;
    let preview_ms = t1.elapsed().as_millis();

    let mut toggle_set: HashSet<usize> = session
        .manifest
        .layers
        .iter()
        .take((session.manifest.layers.len() / 2).max(1))
        .map(|l| l.index)
        .collect();
    if toggle_set.is_empty() && !session.manifest.layers.is_empty() {
        toggle_set.insert(0);
    }
    let t2 = Instant::now();
    let r2 = session.render_subset_to_png(&p2, &toggle_set, 1440, true, false)?;
    let subset_ms = t2.elapsed().as_millis();

    let _ = std::fs::remove_file(&p1);
    let _ = std::fs::remove_file(&p2);

    println!(
        "BENCH_STUDIO_OK open_ms={open_ms} preview_ms={preview_ms} preview_dim={}x{} has_pixels={} layers={} groups={} subset_ms={subset_ms} subset_dim={}x{} subset_pixels={}",
        r1.width,
        r1.height,
        r1.has_pixels,
        session.manifest.layers.len(),
        session.manifest.groups.len(),
        r2.width,
        r2.height,
        r2.has_pixels
    );
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(pos) = args.iter().position(|a| a == "--bench-studio") {
        let Some(target) = args.get(pos + 1) else {
            eprintln!("Usage: WallPull --bench-studio <workshop_dir_or_scene_pkg>");
            std::process::exit(1);
        };
        if let Err(err) = run_bench_studio(target) {
            eprintln!("BENCH_STUDIO_ERR: {err}");
            std::process::exit(1);
        }
        return;
    }

    let self_test = args.iter().any(|a| a == "--self-test");
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }

    if let Err(err) = window::run_app(self_test) {
        eprintln!("WallPull failed to start: {err}");
    }

    unsafe {
        CoUninitialize();
    }
}
