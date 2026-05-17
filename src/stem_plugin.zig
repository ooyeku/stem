const api = @import("sdk/api.zig");
pub const protocol = @import("kernel/protocol.zig");

pub const createPlugin = api.createPlugin;
pub const PluginContext = api.PluginContext;
pub const PluginMessage = api.PluginMessage;
pub const PluginConfig = api.PluginConfig;

pub const EditorStateView = protocol.EditorStateView;
pub const PluginEvent = protocol.PluginEvent;
pub const NotificationLevel = protocol.NotificationLevel;
pub const Mode = protocol.Mode;
pub const StatusAlignment = protocol.StatusAlignment;

pub const PanelPosition = protocol.PanelPosition;
pub const PluginInfo = protocol.PluginInfo;

pub const log = api.log;
pub const logDebug = api.logDebug;
pub const logWarn = api.logWarn;
pub const logError = api.logError;
pub const registerCommand = api.registerCommand;
pub const executeCoreCommand = api.executeCoreCommand;
pub const handleStandardMessages = api.handleStandardMessages;
pub const deinitSdk = api.deinitSdk;

pub const requestEditorState = api.requestEditorState;

pub const subscribeEvent = api.subscribeEvent;
pub const unsubscribeEvent = api.unsubscribeEvent;
pub const emitEvent = api.emitEvent;
pub const subscribeCustomEvent = api.subscribeCustomEvent;

pub const setConfig = api.setConfig;
pub const getConfig = api.getConfig;

pub const showNotification = api.showNotification;
pub const showInfo = api.showInfo;
pub const showWarning = api.showWarning;
pub const showError = api.showError;

pub const createStatusItem = api.createStatusItem;
pub const updateStatusItem = api.updateStatusItem;
pub const destroyStatusItem = api.destroyStatusItem;

pub const createPanel = api.createPanel;
pub const updatePanelContent = api.updatePanelContent;
pub const updatePanelScroll = api.updatePanelScroll;
pub const destroyPanel = api.destroyPanel;

pub const openBuffer = api.openBuffer;
pub const getBufferContent = api.getBufferContent;
pub const switchBuffer = api.switchBuffer;

pub const requestPluginList = api.requestPluginList;
pub const decodePluginList = api.decodePluginList;
pub const loadPlugin = api.loadPlugin;
pub const unloadPlugin = api.unloadPlugin;

pub const vaxis = api.vaxis;
