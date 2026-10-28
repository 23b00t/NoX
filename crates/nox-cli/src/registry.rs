//! `/etc/nox/registry.json`: the data Nix writes for the tools that run
//! inside nox (NoX module programs.nox, sections from the tool modules).
//! `NOX_REGISTRY` points elsewhere (tests, comparisons).

use std::fs;

use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use serde::Deserialize;

pub const PATH: &str = "/etc/nox/registry.json";

/// One section of the registry; a missing section is the default
pub fn section<T: DeserializeOwned + Default>(key: &str) -> Result<T> {
    let path = std::env::var("NOX_REGISTRY").unwrap_or_else(|_| PATH.into());
    let text = fs::read_to_string(&path).with_context(|| format!("reading {path}"))?;
    parse_section(&text, key).with_context(|| format!("parsing {path}"))
}

fn parse_section<T: DeserializeOwned + Default>(text: &str, key: &str) -> Result<T> {
    let value: serde_json::Value = serde_json::from_str(text)?;
    match value.get(key) {
        Some(v) => Ok(T::deserialize(v)?),
        None => Ok(T::default()),
    }
}

/// `domains`: every VM and image domain of the registry, in its order
/// (vm-run, manage-vms; NoX nixos/dom0/tools/vm-run.nix)
#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Domain {
    pub name: String,
    /// Short alias (vm-run accepts it too)
    #[serde(default)]
    pub short: Option<String>,
    /// systemd unit without `.service` (microvm@… / xen-image@…)
    pub unit: String,
    /// Login user in the VM (vm-run -u)
    #[serde(default)]
    pub user: String,
    /// Image domain (Whonix, kali): its terminal is x-terminal-emulator
    #[serde(default)]
    pub image: bool,
    /// nox-relay serves its wprs: GUI and terminals over vm-gui
    #[serde(default)]
    pub wprs: bool,
    /// Image domain whose terminal is foot from the store disk
    #[serde(default)]
    pub foot_image: bool,
    /// registry `storeGroup`
    #[serde(default)]
    pub store_group: Option<String>,
    /// registry `disposable` (manage-vms --fresh)
    #[serde(default)]
    pub disposable: bool,
}

impl Domain {
    pub fn service(&self) -> String {
        format!("{}.service", self.unit)
    }
}

pub fn domains() -> Result<Vec<Domain>> {
    section("domains")
}

/// A domain by name or short alias
pub fn find<'a>(domains: &'a [Domain], key: &str) -> Option<&'a Domain> {
    domains
        .iter()
        .find(|d| d.name == key || d.short.as_deref() == Some(key))
}

#[cfg(test)]
pub fn sample() -> Vec<Domain> {
    parse_section(
        r#"{"vms":["chat"],"domains":[
          {"name":"chat","short":"c","unit":"microvm@chat","user":"user","wprs":true,"storeGroup":"desktop"},
          {"name":"builder","unit":"microvm@builder","user":"builder"},
          {"name":"disp","unit":"microvm@disp","user":"user","wprs":true,"disposable":true},
          {"name":"whonix-gateway","short":"wg","unit":"xen-image@whonix-gateway","user":"user","image":true,"wprs":true,"footImage":true},
          {"name":"whonix-workstation","short":"ww","unit":"xen-image@whonix-workstation","user":"user","image":true,"wprs":true}
        ]}"#,
        "domains",
    )
    .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sections_and_lookup() {
        let d = sample();
        assert_eq!(d.len(), 5);
        assert_eq!(find(&d, "c").unwrap().name, "chat");
        assert_eq!(
            find(&d, "wg").unwrap().service(),
            "xen-image@whonix-gateway.service"
        );
        assert!(find(&d, "nope").is_none());
        assert_eq!(d[0].store_group.as_deref(), Some("desktop"));
        assert!(d[3].foot_image && d[3].image && !d[4].foot_image);
        let none: Vec<Domain> = parse_section(r#"{"vms":[]}"#, "domains").unwrap();
        assert!(none.is_empty());
    }
}
