use std::env;
use std::error::Error;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use lib_flutter_rust_bridge_codegen::codegen::{
    self as frb_codegen, Config as FrbConfig, MetaConfig as FrbMetaConfig,
};

type DynError = Box<dyn Error>;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), DynError> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("frb") => {
            // Offline fork: the photos app is the only bridge target.
            if !matches!(args.next().as_deref(), None | Some("photos")) || args.next().is_some() {
                return Err(usage_error());
            }
            generate_frb()
        }
        _ => Err(usage_error()),
    }
}

fn usage_error() -> DynError {
    "usage: cargo codegen frb [photos]".into()
}

fn generate_frb() -> Result<(), DynError> {
    let rust_root = rust_root()?;
    let repo_root = rust_root
        .parent()
        .ok_or("failed to resolve repo root from rust/tools/codegen")?;

    let package_dir = repo_root.join("mobile/apps/photos");
    let generated_dir = package_dir.join("lib/src/rust");
    if generated_dir.exists() {
        fs::remove_dir_all(&generated_dir)?;
    }
    generate_frb_package(&package_dir)?;
    format_frb_bindings()
}

fn generate_frb_package(package_dir: &Path) -> Result<(), DynError> {
    let previous_dir = env::current_dir().map_err(|error| {
        format!("failed to capture current directory before generating FRB bindings: {error}")
    })?;

    env::set_current_dir(package_dir).map_err(|error| {
        format!(
            "failed to enter {} before generating FRB bindings: {error}",
            package_dir.display()
        )
    })?;

    let result = FrbConfig::from_files_auto().and_then(|config| {
        let config = FrbConfig::merge(
            FrbConfig {
                build_runner: Some(false),
                dart_fix: Some(false),
                dart_format: Some(false),
                ..Default::default()
            },
            config,
        );
        frb_codegen::generate(config, FrbMetaConfig { watch: false })
    });

    env::set_current_dir(&previous_dir).map_err(|error| {
        format!(
            "failed to restore current directory to {}: {error}",
            previous_dir.display()
        )
    })?;

    result?;

    let dart = if cfg!(windows) { "dart.bat" } else { "dart" };
    run_command(
        Command::new(dart)
            .args(["run", "build_runner", "build"])
            .current_dir(package_dir),
        format!("failed to generate Dart code in {}", package_dir.display()),
    )?;
    run_command(
        Command::new(dart)
            .args(["format", "lib/src/rust"])
            .current_dir(package_dir),
        format!("failed to format Dart code in {}", package_dir.display()),
    )
}

fn format_frb_bindings() -> Result<(), DynError> {
    let rust_root = rust_root()?;
    let mut command = Command::new("cargo");
    command.arg("fmt").arg("-p").arg("ente-photos-frb");
    command.current_dir(rust_root);
    run_command(
        &mut command,
        "failed to format generated FRB Rust bindings".to_owned(),
    )
}

fn rust_root() -> Result<PathBuf, DynError> {
    let root = env::current_dir()?;
    if !root.join("Cargo.toml").is_file() {
        return Err("run cargo codegen from the Rust workspace root".into());
    }
    Ok(root)
}

fn run_command(command: &mut Command, error_context: String) -> Result<(), DynError> {
    let program = command.get_program().to_os_string();
    let args = command
        .get_args()
        .map(OsStr::to_os_string)
        .collect::<Vec<_>>();
    let status = command.status().map_err(|error| {
        format!(
            "{error_context}: failed to start {}: {error}",
            render_command(&program, &args)
        )
    })?;

    if status.success() {
        return Ok(());
    }

    Err(format!(
        "{error_context}: {} exited with status {status}",
        render_command(&program, &args)
    )
    .into())
}

fn render_command(program: &OsStr, args: &[std::ffi::OsString]) -> String {
    let mut parts = Vec::with_capacity(args.len() + 1);
    parts.push(program.to_string_lossy().into_owned());
    parts.extend(args.iter().map(|arg| arg.to_string_lossy().into_owned()));
    parts.join(" ")
}
