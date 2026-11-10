# Building/installing from WSL (Windows) — usbmuxd over portproxy

> Dev notes for the contributor-side loop on WSL. The user-facing install
> instructions are in the [README](../README.md).

Forwarding USB into WSL through usbipd-win breaks usbmuxd on packets > 64 KB
([xtool#19](https://github.com/xtool-org/xtool/issues/19),
[usbmuxd#247](https://github.com/libimobiledevice/usbmuxd/issues/247)).

The working alternative to usbipd — Apple's TCP-usbmuxd (Apple Mobile Device
Service), proxied from WSL:

1. Install **Apple Devices**
   ([Microsoft Store](https://apps.microsoft.com/detail/9np83lwlpz9k)) —
   the service must be running.
2. Windows (admin, UAC):
   ```powershell
   netsh interface portproxy set v4tov4 listenaddress=<WSL gateway> listenport=27015 connectaddress=127.0.0.1
   New-NetFirewallRule -DisplayName "WSL usbmuxd 27015" -Direction Inbound -InterfaceAlias "vEthernet (Hyper-V firewall)" -Protocol TCP -LocalPort 27015 -Action Allow
   ```
   `<WSL gateway>` — the first address from `ip route list default` in WSL
   (with NAT that is the Windows IP, e.g. `172.28.112.1`).
3. In WSL:
   ```bash
   export USBMUXD_SOCKET_ADDRESS="$(ip route list default | awk '{print $3}'):27015"
   xtool dev run
   ```

⚠ The WSL gateway IP may change after a Windows reboot — repeat the
`netsh portproxy` with the new address. Do **not** use
`listenaddress=0.0.0.0` (it exposes the socket to the network).

`.env` in the repo root sets `USBMUXD_SOCKET_ADDRESS` for this scheme.
