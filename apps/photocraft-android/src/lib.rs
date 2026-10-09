//! PhotoCraft on Android: native egui/eframe on wgpu (Vulkan/GLES).
//!
//! Hosts the complete [`photocraft_ui_egui::PhotocraftApp`] desktop user interface as a native
//! Android application via Android's `NativeActivity` lifecycle and eframe's Android backend.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

#[cfg(target_os = "android")]
use std::sync::{Arc, Mutex};

#[cfg(target_os = "android")]
use photocraft_codecs::{ChannelLayout, EncodeOptions, Image};
#[cfg(target_os = "android")]
use photocraft_doc::Document;
#[cfg(target_os = "android")]
use photocraft_engine::Session;
#[cfg(target_os = "android")]
use photocraft_ui_egui::theme::ThemeKind;
#[cfg(target_os = "android")]
use photocraft_ui_egui::{PhotocraftApp, Services};

#[cfg(target_os = "android")]
type Inbox = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

/// Android preferences path under internal app storage.
#[cfg(target_os = "android")]
const ANDROID_PREFS_DIR: &str = "/data/data/ai.storyteller.photocraft/files";
#[cfg(target_os = "android")]
const ANDROID_PREFS_FILE: &str = "/data/data/ai.storyteller.photocraft/files/preferences.json";

/// Construct the [`Services`] injection struct tailored for Android.
#[cfg(target_os = "android")]
fn android_services(inbox: Inbox) -> Services {
    Services {
        import: Some(Box::new(|name: &str, bytes: &[u8]| {
            photocraft_io::import(name, bytes)
                .map(|r| (r.document, r.warnings))
                .map_err(|e| e.to_string())
        })),
        export: Some(Box::new(|doc: &Document, path: &str, settings: &photocraft_ui_egui::ExportSettings| {
            let mut opts = photocraft_io::ExportOptions::default();
            if let Some(q) = settings.jpeg_quality {
                opts.encode.jpeg_quality = q;
            }
            opts.encode.webp_lossless = settings.webp_lossless;
            if let Some(q) = settings.webp_quality {
                opts.encode.webp_quality = q;
            }
            opts.tiff_layers = settings.tiff_layers;
            opts.xmp = if settings.xmp_all {
                photocraft_io::XmpEmbed::All
            } else {
                photocraft_io::XmpEmbed::None
            };
            photocraft_io::export(doc, path, &opts)
                .map(|r| (r.bytes, r.warnings))
                .map_err(|e| e.to_string())
        })),
        write: Some(Box::new(|path: &str, bytes: &[u8]| {
            if let Some(parent) = std::path::Path::new(path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(path, bytes).map_err(|e| e.to_string())
        })),
        encode_png: Some(Box::new(|w, h, rgba| {
            let img = Image::from_u8(w, h, ChannelLayout::Rgba, rgba.to_vec())
                .map_err(|e| e.to_string())?;
            photocraft_codecs::encode(&img, photocraft_codecs::Format::Png, &EncodeOptions::default())
                .map_err(|e| e.to_string())
        })),
        inbox: Some(inbox),
        load_prefs: Some(Box::new(|| {
            std::fs::read_to_string(ANDROID_PREFS_FILE).ok()
        })),
        save_prefs: Some(Box::new(|text: &str| {
            let _ = std::fs::create_dir_all(ANDROID_PREFS_DIR);
            std::fs::write(ANDROID_PREFS_FILE, text).map_err(|e| e.to_string())
        })),
        ..Default::default()
    }
}

/// The main Android entry point invoked by Android's `NativeActivity`.
///
/// SAFETY: `android_main` must be exported with C ABI without mangling so that the Android
/// NativeActivity dynamic library loader finds it.
#[cfg(target_os = "android")]
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn android_main(app: winit::platform::android::activity::AndroidApp) {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("PhotoCraft"),
    );

    log::info!("PhotoCraft initializing on Android (eframe + wgpu)");

    let options = eframe::NativeOptions {
        android_app: Some(app),
        renderer: eframe::Renderer::Wgpu,
        ..Default::default()
    };

    let run_result = eframe::run_native(
        "PhotoCraft",
        options,
        Box::new(|cc| {
            PhotocraftApp::setup_context(&cc.egui_ctx, ThemeKind::Pro);
            let inbox: Inbox = Arc::default();
            let mut app = PhotocraftApp::new(Session::new(), android_services(inbox));
            app.set_theme(&cc.egui_ctx, ThemeKind::Pro);
            if let Some(rs) = cc.wgpu_render_state.clone() {
                log::info!("PhotoCraft Android wgpu backend: {:?}", rs.adapter.get_info().backend);
                app.set_wgpu(rs);
            }
            Ok(Box::new(app))
        }),
    );

    if let Err(err) = run_result {
        log::error!("PhotoCraft Android terminated with error: {err:?}");
    }
}

/// Helper for non-Android targets to ensure clean compilation and testability in CI.
#[cfg(not(target_os = "android"))]
pub fn check_target() -> &'static str {
    "PhotoCraft Android runner"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn android_crate_compiles_and_links() {
        #[cfg(not(target_os = "android"))]
        assert_eq!(check_target(), "PhotoCraft Android runner");
    }
}
