use anyhow::{bail, Context, Result};
use std::path::Path;
use std::process::Command;

pub struct InstallOptions {
    pub use_dkms: bool,
    pub hold_packages: bool,
    pub run_file: String,
}

/// Invoke the privileged install script via pkexec and wait for it.
///
/// The install is repo-style: the new driver goes on disk while the
/// current one keeps running, and the switch happens at the next
/// reboot. Nothing touches the live session, so a plain blocking call
/// is safe — the GUI stays up the whole time.
pub fn run_privileged_install(opts: &InstallOptions) -> Result<()> {
    let script = "/usr/lib/greenlight/privileged-install.sh";

    if !Path::new(script).exists() {
        bail!("Privileged install script not found at {}", script);
    }
    if !Path::new(&opts.run_file).exists() {
        bail!("Run file not found: {}", opts.run_file);
    }

    let mut args = vec![script.to_string(), opts.run_file.clone()];
    if opts.use_dkms {
        args.push("--dkms".to_string());
    }
    if opts.hold_packages {
        args.push("--hold".to_string());
    }

    let status = Command::new("pkexec")
        .args(&args)
        .status()
        .context("Failed to launch pkexec — is polkit installed?")?;

    if !status.success() {
        let code = status.code().unwrap_or(-1);
        if code == 126 || code == 127 {
            bail!("Authentication was cancelled.");
        }
        bail!(
            "Install script exited with code {} (see /var/log/greenlight.log)",
            code
        );
    }

    Ok(())
}
