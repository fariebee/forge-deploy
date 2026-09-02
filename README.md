# Forge — self-host bundle

Runtime files for running [Forge](https://forge.beesworx.co.za): compose stack,
Caddy, PgBouncer, monitoring, and the installer. The app image is public at
`ghcr.io/fariebee/forge`; the source repo is private. Synced automatically from
CI — don't edit here, changes are overwritten.

```bash
curl -fsSL https://raw.githubusercontent.com/fariebee/forge-deploy/main/scripts/deploy.sh | sudo bash
```

Licensed under [FSL-1.1-ALv2](./LICENSE.md).
