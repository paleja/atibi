# rpi-streamer

Purpose-built Raspberry Pi appliance image: a music streamer (cliamp +
Raspberry Pi DAC+ HAT) that boots from a cold power cut to audible music in
under 10 seconds and survives hard power-cuts indefinitely.

- Product requirements: [docs/PRD.md](docs/PRD.md)

Repo layout:

- `docs/` — PRD, design notes, measurement logs
- `image/` — image build and customization scripts (to be created)
- `config/` — reference config files: config.txt, asound.conf, systemd units,
  radios.toml (to be created)
