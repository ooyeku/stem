//! Re-exports of the stable C ABI for plugin authors. Plugins should
//! `@import("stem")` rather than this file directly — `src/stem_plugin.zig`
//! pulls these in as part of the public SDK.
//!
//! The legacy `PluginInterface` field-by-field struct is gone; v3
//! consolidates the interface in `abi.zig` so plugins and the host see
//! exactly the same extern types.

const abi = @import("abi.zig");

pub const PLUGIN_VERSION: u32 = abi.ABI_VERSION;
pub const PluginInterface = abi.PluginInterface;
pub const PluginCapabilities = abi.Capabilities;
pub const PluginHandle = abi.PluginHandle;
pub const LogLevel = abi.LogLevel;
pub const Status = abi.Status;
