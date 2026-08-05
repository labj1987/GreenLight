use anyhow::{Context, Result};
use regex::Regex;
use scraper::{Html, Selector};

#[derive(Debug, Clone)]
pub struct DriverVersion {
    pub version: String,
    pub filename: String,
    pub url: String,
}

const NVIDIA_BASE: &str = "https://download.nvidia.com/XFree86/Linux-x86_64/";

pub async fn fetch_versions() -> Result<Vec<DriverVersion>> {
    let client = reqwest::Client::builder()
        .user_agent(concat!("greenlight/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let html = client
        .get(NVIDIA_BASE)
        .send()
        .await
        .context("Failed to reach NVIDIA download server")?
        .text()
        .await?;

    let document = Html::parse_document(&html);
    let selector = Selector::parse("a[href]").unwrap();
    let ver_re = Regex::new(r"^(\d+\.\d+(?:\.\d+)?)/?$").unwrap();

    let mut versions: Vec<DriverVersion> = document
        .select(&selector)
        .filter_map(|el| {
            let href = el.value().attr("href")?;
            let caps = ver_re.captures(href)?;
            let version = caps[1].to_string();
            let filename = format!("NVIDIA-Linux-x86_64-{}.run", version);
            let url = format!("{}{}/{}", NVIDIA_BASE, version, filename);
            Some(DriverVersion { version, filename, url })
        })
        .collect();

    versions.sort_by(|a, b| {
        let av: Vec<u32> = a.version.split('.').filter_map(|s| s.parse().ok()).collect();
        let bv: Vec<u32> = b.version.split('.').filter_map(|s| s.parse().ok()).collect();
        bv.cmp(&av)
    });

    Ok(versions)
}

/// Fetch the SHA256 checksum for a given version's .run file.
pub async fn fetch_checksum(version: &DriverVersion) -> Result<Option<String>> {
    let client = reqwest::Client::builder()
        .user_agent(concat!("greenlight/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(15))
        .build()?;

    let ver_str = &version.version;

    // Try .manifest first
    let manifest_url = format!("{}{}/{}", NVIDIA_BASE, ver_str, ".manifest");
    if let Ok(r) = client.get(&manifest_url).send().await {
        if r.status().is_success() {
            let text = r.text().await?;
            for line in text.lines() {
                if line.contains(&version.filename) {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if let Some(hash) = parts.first() {
                        if hash.len() == 64 {
                            return Ok(Some(hash.to_string()));
                        }
                    }
                }
            }
        }
    }

    // Fallback: <filename>.sha256sum
    let sha_url = format!("{}{}/{}.sha256sum", NVIDIA_BASE, ver_str, version.filename);
    if let Ok(r) = client.get(&sha_url).send().await {
        if r.status().is_success() {
            let text = r.text().await?;
            let hash = text.split_whitespace().next().unwrap_or("").to_string();
            if hash.len() == 64 {
                return Ok(Some(hash));
            }
        }
    }

    Ok(None)
}
