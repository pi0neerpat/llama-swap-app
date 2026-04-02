# Llama Swap App

A native macOS app that launches [llama-swap](https://github.com/mostlygeek/llama-swap) and displays its web UI in a WebKit window.

## What It Does

1. Starts `llama-swap` as a background process (`--config ~/.llama-swap/config.yaml --listen localhost:8080`)
2. Waits for the server to become ready (polls for up to 10 seconds)
3. Opens a window with a WebView showing `http://localhost:8080`
4. Terminates the llama-swap process when the app quits

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
