# Llama Swap App

A native macOS app that launches [llama-swap](https://github.com/mostlygeek/llama-swap) and displays its web UI in a WebKit window.

The app runs from a menu-bar icon and stays out of the Dock until its window is opened. Close the window to return to menu-bar-only mode without quitting. Choose **Settings → Start at Login** to launch the app automatically when you sign in; macOS may require approval in System Settings.

After a model becomes ready, the app remembers the most recently ready local model. On the next launch it restores that model with a model-specific `/props` request, without sending a chat prompt.

## What It Does

1. Starts `llama-swap` as a background process (`--config ~/.llama-swap/config.yaml --listen localhost:8080`)
2. Opens a window that shows startup progress while it waits for the server (up to 10 seconds)
3. Displays the llama-swap output and an actionable error if startup or page loading fails
4. Loads the web UI at `http://localhost:8080` once the server responds
5. Keeps llama-swap running when the window closes and terminates it when the app quits

The status and output panel collapses when the web UI loads successfully. Use **Show Details** to reopen it, or **Retry** after correcting a startup issue or if the web UI fails to load.

## Prerequisites

- macOS 13.0+
- `llama-swap` installed at `/opt/homebrew/bin/llama-swap`
- A config file at `~/.llama-swap/config.yaml`

## Build

```bash
./build.sh
```

This compiles the app and installs it to `~/Applications/Llama Swap.app`.

## Launch

Open `~/Applications/Llama Swap.app` from Finder, or:

```bash
open ~/Applications/Llama\ Swap.app
```
