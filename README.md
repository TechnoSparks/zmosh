<h1>
<p align="center">
  <img src="./docs/logo.png" alt="Logo" width="128">
  <br>zmosh
</h1>
<p align="center">
  Session persistence with auto-reconnect for terminal processes.
  <br />
  CLI + C library (macOS, iOS, Linux)
  <br />
  Built on <a href="https://github.com/neurosnap/zmx">zmx</a> · Powered by <a href="https://github.com/ghostty-org/ghostty">libghostty-vt</a>
</p>

## what is zmosh

zmosh provides **encrypted UDP auto-reconnect** for remote [zmx](https://github.com/neurosnap/zmx) terminal sessions — bringing the roaming and reconnect model from [mosh](https://mosh.org) to `zmx`.

`zmosh` operates alongside your existing `zmx` installation. It uses `zmx` as an external library (`libzmx`), acting as a roaming gateway between local and remote terminals.

**How remote mode works:** `zmosh` bootstraps an SSH connection to start a UDP gateway on the remote host (`zmosh serve <session>`), negotiates a one-time cryptographic session key, and then transitions to encrypted UDP datagrams. If your IP changes (Wi-Fi → cellular, VPN toggle, laptop sleep/wake), the session stays alive seamlessly without reconnecting or losing state.

## features

- **Encrypted UDP transport**: authenticated and encrypted datagrams with zero external crypto dependencies.
- **Auto-reconnect & Roaming**: seamless survival through IP changes, network hops, and sleep/wake cycles.
- **Anti-replay protection**: monotonic sequence numbers to prevent packet replay.
- **MTU-safe chunking**: avoids UDP packet fragmentation across diverse networks.
- **Native Scrollback & Full Terminal Support**: retains 1:1 fidelity with full color, truecolor, and modern terminal features via `zmx`.
- **Decoupled Architecture**: network transport layer is separate from the `zmx` daemon; local sessions are untouched.

## comparison with remote terminal tools

| Feature | zmosh | mosh | Eternal Terminal | tssh |
| --- | --- | --- | --- | --- |
| Encrypted transport | ✓ | ✓ (AES-128-OCB) | ✓ (AES) | ✓ (SSH) |
| UDP auto-reconnect | ✓ | ✓ | ✗ (TCP) | ✗ (TCP) |
| IP roaming | ✓ | ✓ | ✗ | ✗ |
| Session persistence (detach/reattach) | ✓ | ✗ | ✓ | ✗ |
| Terminal state restore | ✓ (libghostty-vt) | ✓ (own VT) | ✓ | ✗ |
| Native terminal scrollback | ✓ | ✗ | ✓ | ✓ |
| Multiple clients per session | ✓ | ✗ | ✗ | ✗ |
| Local sessions (no network) | ✓ (via zmx) | ✗ | ✗ | ✗ |
| Anti-replay protection | ✓ | ✓ | ✓ | ✓ |
| Predictive local echo | ✗ | ✓ | ✗ | ✗ |
| Window management | ✗ | ✗ | ✗ | ✗ |

## install

### pre-built binaries

Pre-built binaries for Linux and macOS (`x86_64` and `aarch64`) are available on the [Releases](https://github.com/matthyx/zmosh/releases) page.

Download and extract the archive for your platform, then move the binary to your PATH:

```bash
tar -xzf zmosh-1.0.0-linux-x86_64.tar.gz
sudo mv zmosh /usr/local/bin/
```

### building from source

- Requires **Zig 0.17.0** or later
- Clone the repository and build:

```bash
git clone https://github.com/matthyx/zmosh.git
cd zmosh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
# Ensure ~/.local/bin is in your PATH
```

### build targets

| Command | Description |
| --- | --- |
| `zig build` | Build `zmosh` binary for host platform |
| `zig build test` | Run test suite |
| `zig build check` | Type-check without code generation (for ZLS/LSP) |
| `zig build release` | Cross-compile release tarballs and SHA256 checksums for Linux and macOS |

### libzmosh (C library)

`zmosh` provides a clean C API (`include/zmosh/zmosh.h`) to embed roaming terminal sessions in native desktop or mobile applications:

```c
#include <zmosh/zmosh.h>

// Connect to a remote zmosh gateway
zmosh_session_t *session = zmosh_connect(
    host, port, key_base64,
    rows, cols,
    output_cb,   // called with terminal output bytes
    state_cb     // called on connection state changes
);

// Send terminal input and resize events
zmosh_send_input(session, data, len);
zmosh_resize(session, rows, cols);

// Disconnect and cleanup
zmosh_disconnect(session);
zmosh_destroy(session);
```

## usage

```
Usage: zmosh attach <host> <session>
       zmosh serve <session>
```

### connecting to a remote session

To connect to a session named `dev` on a remote server:

```bash
zmosh attach myserver dev
```

1. `zmosh` connects to `myserver` via SSH and executes `zmosh serve dev`.
2. The remote gateway starts the session via `zmx`, binds a UDP port, and outputs the connection key.
3. The local `zmosh` client switches transparently to encrypted UDP datagrams.

### running the gateway manually

On the remote server, you can also launch the gateway directly:

```bash
zmosh serve dev
```

## acknowledgements

- **[zmx](https://github.com/neurosnap/zmx)** by [Eric Bower](https://github.com/neurosnap) for the session persistence daemon, IPC protocol, and terminal multiplexer.
- **[mosh](https://mosh.org)** by Keith Winstein and team for pioneering roaming datagrams on unreliable networks.
- **[Ghostty](https://ghostty.org)** for `libghostty-vt`.
- **[mmonad](https://github.com/mmonad)** for the initial prototype of `zmosh`.

## license

MIT
