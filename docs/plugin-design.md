# Stem Plugin System

This document describes the plugin system architecture and how to develop plugins for stem.

## Overview

Stem's plugin system is built on:
- **Dynamic Libraries**: Plugins are compiled as shared libraries (`.dylib`, `.so`, `.dll`)
- **Native Zig Interface**: Simple struct-based plugin interface
- **Actor Model**: Each plugin runs in its own thread with message-passing communication
- **Vigil Inboxes**: Thread-safe message queues for plugin ↔ core communication

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Plugin A      │    │   Plugin B      │    │   Plugin C      │
│   Thread        │    │   Thread        │    │   Thread        │
│  ┌───────────┐  │    │  ┌───────────┐  │    │  ┌───────────┐  │
│  │   Inbox   │◄─┼────┼──│   Inbox   │◄─┼────┼──│   Inbox   │  │
│  └───────────┘  │    │  └───────────┘  │    │  └───────────┘  │
└────────┬────────┘    └────────┬────────┘    └────────┬────────┘
         │                      │                      │
         └─────────────┬────────┴────────────┬─────────┘
                       │                     │
                       ▼                     ▼
          ┌─────────────────────┐   ┌─────────────────────┐
          │   Core Thread       │   │   Event Bus         │
          │   PluginManager     │   │   (Shared events)   │
          │   CommandRegistry   │   └─────────────────────┘
          └─────────────────────┘
```

## Plugin Locations

- **User plugins**: `~/.stem/plugins/` (auto-loaded on startup)
- **Bundled plugins**: `bundled/plugins/` (built with stem)

## Creating a Plugin

### Project Structure

```
my-plugin/
├── build.zig
├── build.zig.zon
└── src/
    └── main.zig
```

### src/main.zig

```zig
const stem = @import("stem");

// Plugin state (optional)
var plugin_ctx: ?*stem.PluginContext = null;

fn init(ctx: *stem.PluginContext) i32 {
    plugin_ctx = ctx;
    stem.log(ctx, "My Plugin initialized", .{});
    
    // Register commands (optional)
    stem.registerCommand(ctx, "my-plugin.hello", "My Plugin: Hello", "Say hello") catch |err| {
        stem.log(ctx, "Failed to register command: {}", .{err});
        return -1;
    };
    
    return 0;
}

fn deinit(ctx: *stem.PluginContext) void {
    stem.log(ctx, "My Plugin shutting down", .{});
    stem.deinitSdk(ctx);  // Clean up SDK resources
    plugin_ctx = null;
}

fn handleMessage(ctx: *stem.PluginContext, msg: *const stem.PluginMessage) i32 {
    // Handle standard messages (command execution, etc.)
    if (stem.handleStandardMessages(ctx, msg)) {
        return 0;
    }
    // Handle custom messages here
    return 0;
}

// Export the plugin entry point
pub export const plugin_entry = stem.createPlugin(.{
    .name = "my_plugin",
    .description = "My custom stem plugin",
    .init = init,
    .deinit = deinit,
    .handleMessage = handleMessage,
});
```

## SDK API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `createPlugin(config)` | Create a plugin interface from config |
| `log(ctx, fmt, args)` | Log a message with plugin prefix |
| `registerCommand(ctx, id, title, desc, callback)` | Register a command with Core |
| `handleStandardMessages(ctx, msg)` | Handle built-in message types |
| `requestEditorState(ctx, callback)` | Request current editor state |
| `subscribeEvent(ctx, event, callback)` | Subscribe to core events |
| `deinitSdk(ctx)` | Clean up SDK resources (call in deinit) |
| `requestPluginList(ctx, callback)` | Get metadata for all loaded plugins |
| `loadPlugin(ctx, path)` | Request core to load a plugin from path |
| `unloadPlugin(ctx, id)` | Request core to unload a plugin by ID |
| `emitEvent(ctx, name, data)` | Broadcast a custom event to all plugins |
| `subscribeCustomEvent(ctx, name, cb)` | Subscribe to a custom event |

### UI Extension Functions

| Function | Description |
|----------|-------------|
| `createStatusItem(ctx, id, text, align, priority)` | Create a status bar item |
| `updateStatusItem(ctx, id, text)` | Update status item text |
| `destroyStatusItem(ctx, id)` | Remove a status item |
| `createPanel(ctx, id, title, pos, width)` | Create a side panel |
| `updatePanelContent(ctx, id, content)` | Update panel content lines |
| `destroyPanel(ctx, id)` | Remove a panel |

### UI Isolation
The `UIManager` ensures that plugins cannot interfere with each other's UI elements. All UI IDs provided by plugins are internally converted to composite keys in the format `{plugin_id}:{element_id}`. This means two different plugins can both use the ID "status" without conflict.

## Inter-plugin Communication
Plugins can communicate with each other using a shared Event Bus. This is useful for plugins that provide services (like `git`) to notify other plugins (like `plugin-manager` or `status-line`) about state changes.

- **Emitting**: `stem.emitEvent(ctx, "my.event", "payload")`
- **Subscribing**: `stem.subscribeCustomEvent(ctx, "my.event", myCallback)`

## Plugin Management
The `PluginManager` provides a way to inspect and manage the lifecycle of other plugins.

- **Resource Monitoring**: Each plugin's `uptime` and `widget_count` is tracked by the core.
- **Dynamic Loading**: Plugins can be loaded or unloaded at runtime via the `loadPlugin` and `unloadPlugin` APIs.
- **Cleanup**: When a plugin is unloaded, the core automatically cleans up its registered commands, UI items, and event subscriptions.

## Plugin Interface

Plugins export a `plugin_entry` symbol of type `PluginInterface`:

```zig
pub const PluginInterface = struct {
    version: u32 = 1,
    name: []const u8,
    description: []const u8,
    
    // Lifecycle hooks
    init: ?*const fn(ctx: *anyopaque) i32,
    deinit: ?*const fn(ctx: *anyopaque) void,
    handleMessage: ?*const fn(ctx: *anyopaque, msg: *const PluginMessage) i32,
    
    // Capabilities
    capabilities: PluginCapabilities,
};
```

## Plugin Lifecycle

1. **Load**: `PluginManager.loadPlugin()` opens the dynamic library
2. **Validate**: Check `plugin_entry` symbol and version
3. **Initialize**: Create inbox, context, and spawn plugin thread
4. **Init Hook**: Call plugin's `init` function
5. **Message Loop**: Plugin receives and processes messages
6. **Shutdown**: On quit, inbox is closed, thread joins, `deinit` called
7. **Cleanup**: Plugin resources freed

## File Structure

```
src/
├── plugins/
│   ├── interface.zig # Plugin interface definitions
│   ├── api.zig       # Internal API helpers
│   ├── context.zig   # PluginContext (communication channels)
│   ├── manager.zig   # PluginManager (loading, lifecycle)
│   └── plugin.zig    # Plugin struct (state, thread, inbox)
├── sdk/
│   ├── api.zig       # Public SDK for plugin developers
│   └── build.zig     # Build helpers for plugins
└── yap_plugin.zig    # SDK entry point (plugins import this)
```