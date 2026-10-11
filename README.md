# aether-bootstrap

The one script that turns a freshly flashed Raspberry Pi into an
[Aether](https://github.com/mcarli-dev/aether-services) device.

1. Raspberry Pi Imager → Raspberry Pi OS Lite 64-bit, with hostname, user,
   WiFi and SSH key set in the advanced options.
2. On the Pi, as the normal user:

```bash
curl -fsSL https://raw.githubusercontent.com/mcarli-dev/aether-bootstrap/main/bootstrap.sh | sudo bash
```

It installs the base packages and Docker, clones `aether-services` into
`~/aether` (asking for a GitHub token while that repository is private) and
looks for an Aether gateway on the network over mDNS:

- **gateway found** → the Pi joins as a node: a 6-digit code is shown; approve
  it on the gateway (`aether nodes approve <code>` or the GUI Nodes tab) only if
  it matches;
- **no gateway** → it offers to make this Pi the gateway of a new Aether.

Then it runs `aether apply`. Safe to re-run: every step checks before acting.

This file mirrors `bootstrap.sh` in `aether-services`, where it is maintained.
