//! Public SDK module for stem plugins (`@import("stem")` from a plugin).
//!
//! Plugin-side ABI version 3. See `src/plugins/abi.zig` for the
//! boundary types and `src/sdk/api.zig` for the Zig API.

const api = @import("sdk/api.zig");
const abi = @import("plugins/abi.zig");
pub const protocol = @import("kernel/protocol.zig");

// Boundary types
pub const PluginHandle = abi.PluginHandle;
pub const PluginInterface = abi.PluginInterface;
pub const PluginCapabilities = abi.Capabilities;
pub const PluginMessage = protocol.PluginMessage;
pub const ABI_VERSION = abi.ABI_VERSION;

// Protocol re-exports
pub const EditorStateView = protocol.EditorStateView;
pub const PluginEvent = protocol.PluginEvent;
pub const NotificationLevel = protocol.NotificationLevel;
pub const Mode = protocol.Mode;
pub const StatusAlignment = protocol.StatusAlignment;
pub const PanelPosition = protocol.PanelPosition;
pub const PluginInfo = protocol.PluginInfo;

// Entry-point helper
pub const PluginConfig = api.PluginConfig;
pub const createPlugin = api.createPlugin;

// SDK lifecycle (call from activate / deactivate)
pub const bind = api.bind;
pub const unbind = api.unbind;
pub const dispatch = api.dispatch;

// Logging
pub const log = api.log;
pub const logDebug = api.logDebug;
pub const logWarn = api.logWarn;
pub const logError = api.logError;

// Commands & events
pub const registerCommand = api.registerCommand;
pub const executeCoreCommand = api.executeCoreCommand;
pub const subscribeEvent = api.subscribeEvent;
pub const unsubscribeEvent = api.unsubscribeEvent;
pub const emitEvent = api.emitEvent;
pub const subscribeCustomEvent = api.subscribeCustomEvent;

// Async requests
pub const requestEditorState = api.requestEditorState;
pub const getConfig = api.getConfig;
pub const setConfig = api.setConfig;
pub const getBufferContent = api.getBufferContent;
pub const requestPluginList = api.requestPluginList;
pub const decodePluginList = api.decodePluginList;

// Buffers / UI
pub const showNotification = api.showNotification;
pub const showInfo = api.showInfo;
pub const showWarning = api.showWarning;
pub const showError = api.showError;
pub const openBuffer = api.openBuffer;
pub const switchBuffer = api.switchBuffer;
pub const createStatusItem = api.createStatusItem;
pub const updateStatusItem = api.updateStatusItem;
pub const destroyStatusItem = api.destroyStatusItem;
pub const createPanel = api.createPanel;
pub const updatePanelContent = api.updatePanelContent;
pub const destroyPanel = api.destroyPanel;
pub const updatePanelScroll = api.updatePanelScroll;
pub const loadPlugin = api.loadPlugin;
pub const unloadPlugin = api.unloadPlugin;

pub const vaxis = api.vaxis;
