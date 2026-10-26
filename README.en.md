# VCP Suite · Automated Builds

<p align="center">
  <img src="https://img.shields.io/badge/VCPToolBox-Docker-2496ED?style=flat-square&logo=docker&logoColor=white" alt="VCPToolBox">
  <img src="https://img.shields.io/badge/VCPMobile-Android-3DDC84?style=flat-square&logo=android&logoColor=white" alt="VCPMobile">
  <img src="https://img.shields.io/badge/VCPChat-Windows-0078D4?style=flat-square&logo=windows&logoColor=white" alt="VCPChat">
</p>

<p align="center">
  <img src="https://img.shields.io/github/actions/workflow/status/homuraLan/vcp-cicd/vcp-build-release.yml?style=flat-square&label=build" alt="build status">
  <img src="https://img.shields.io/github/v/release/homuraLan/vcp-cicd?style=flat-square&label=release" alt="release">
  <img src="https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20Docker-informational?style=flat-square" alt="platform">
</p>

---

**[中文](README.md) · English**

This repo follows three upstream projects and compiles them into ready-to-use builds.
**No environment setup needed — download and run.**

| Component | What it is | Platform |
| :--- | :--- | :--- |
| ![Docker](https://img.shields.io/badge/-VCPToolBox-2496ED?style=flat-square&logo=docker&logoColor=white) | AI tool-calling server | Docker |
| ![Android](https://img.shields.io/badge/-VCPMobile-3DDC84?style=flat-square&logo=android&logoColor=white) | Mobile client | Android 8.0+ |
| ![Windows](https://img.shields.io/badge/-VCPChat-0078D4?style=flat-square&logo=windows&logoColor=white) | Desktop client | Windows 10/11 |

## Download

<p align="center">
  <a href="../../releases/latest">
    <img src="https://img.shields.io/badge/⬇%20Download%20Latest-Releases-2ea44f?style=for-the-badge" alt="Download">
  </a>
</p>

Open [**Releases**](../../releases/latest) and pick what you need:

| File | Platform | Notes |
| :--- | :--- | :--- |
| `VCPMobile-v<version>-<hash>.apk` | Android | Installer; copy to phone and tap to install |
| `VCPMobile-latest.apk` | Android | Same file, fixed name — handy for bookmarking |
| `VCPChat-Setup-<version>-<hash>.exe` | Windows | Installer; double-click to run |
| `VCPChat-Portable-<version>-<hash>.zip` | Windows | Portable; unzip and run |
| `vcptoolbox-<version>-<hash>-linux-amd64.tar.gz` | Linux | Server binary; extract and run |

`<hash>` in the filename is the short SHA of the upstream commit, so you can trace
every build back to exact source. For the desktop client, `<version>` is the upstream
commit date, e.g. `VCPChat-Setup-2026.10.25-74d4a491.exe`.

Every file ships with a matching `.sha256`, plus an aggregate `SHA256SUMS`:

```bash
sha256sum -c SHA256SUMS
```

Releases contain only build artifacts and checksums — nothing else.

### The server also has a no-install binary

Besides the Docker image, the server is available as a plain tarball that runs
**without Docker**:

```bash
tar -xzf vcptoolbox-<version>-<hash>-linux-amd64.tar.gz
cd app
node main.js
```

All dependencies are bundled (`node_modules`, `pydeps`, compiled native modules,
and the Rust sub-programs used by plugins). No `npm install`, no compiler needed.

`BUILD-INFO.txt` inside the archive records the commit, build time and runtime.

> This archive targets Alpine/musl. On a glibc system (most distros), the container
> image is easier:
> ```bash
> docker pull homuralan/vcptoolbox:latest         # latest
> docker pull homuralan/vcptoolbox:v1.13.0        # pinned to an upstream version
> docker pull homuralan/vcptoolbox:<hash>         # pinned to an upstream commit
> ```
>
> All three tags point at the same image. Use `latest` day to day, `v<version>` to
> follow upstream releases, and `<hash>` when rolling back — it never gets overwritten.

## Component notes

### VCPMobile · Android

- Requires **Android 8.0** or newer
- Server address is pre-configured at build time — no manual setup
- In-place upgrade supported; just install the new APK

### VCPChat · Windows

- Windows 10 / 11, 64-bit
- Set the server address in Settings on first launch
- New versions install over the old one automatically

### VCPToolBox · Server

<a href="https://hub.docker.com/r/homuralan/vcptoolbox"><img src="https://img.shields.io/docker/pulls/homuralan/vcptoolbox?style=flat-square&logo=docker&logoColor=white" alt="docker pulls"></a>

```bash
docker pull homuralan/vcptoolbox:latest
```

| Tag | Meaning |
| :--- | :--- |
| `latest` | Most recent successful build |
| `v1.13.0` style | Matches the upstream version and the Release tag |
| `dd4f7032` style | Pinned to a specific upstream commit, for rollbacks |

Old tags are pruned automatically — the newest 10 versions are kept, `latest` always
survives. For anything older, grab the tarball from Releases.

The image needs a config file to start. See the upstream
[VCPToolBox](https://github.com/lioensky/VCPToolBox) deployment docs.
The Docker Hub description is updated automatically on every build.

## Updating

The build pipeline publishes new versions; deployed machines pull them on a schedule:

| Component | How updates arrive |
| :--- | :--- |
| Server | Self-hosted runner pulls the new image and restarts the container |
| Desktop | Self-hosted runner downloads the installer and installs it silently |
| Android | APK is served from a local page — you install it when you want |

Interval is configurable per component (see FAQ).

## Build rules

**A component is only rebuilt when its upstream actually changed.** The three
upstreams are checked independently:

```
on every push, and every 6 hours
      │
      ├── VCPToolBox has new commits? → build server only (image + Linux binary)
      ├── VCPMobile  has new commits? → build APK only
      └── VCPChat    has new commits? → build Windows client only
```

Unchanged components are skipped, so no build minutes are wasted. The last successful
commit is recorded on the `state` branch and compared by SHA — no reliance on version
numbers or tags.

So a Release containing only one or two files is **expected** — the other components
simply didn't change. For skipped components, the run summary links to the release
where that component was actually built.

## FAQ

<details>
<summary><b>APK says "App not installed"</b></summary>

Signature mismatch. If you already have an app with the same name from another source,
uninstall it first.

</details>

<details>
<summary><b>App can't reach the server</b></summary>

The built-in address is a LAN address. Make sure the phone and server are on the same
network, or change the address in the app settings.

</details>

<details>
<summary><b>How often does it update?</b></summary>

Two independent layers:

**Upstream builds** — compiled whenever there is a new commit; the upstreams are
checked on every push and every 6 hours. No rate limit here: the goal is to keep
Releases on the latest source.

**Local pulls** — how often a deployed machine fetches a new version. Defaults to once
a week, configurable per component:

| Repo variable | Controls | Default |
| :--- | :--- | :--- |
| `VCP_SERVER_INTERVAL_H` | Server pull interval | `168` (hours = 1 week) |
| `VCP_CHAT_INTERVAL_H` | Desktop pull interval | `168` (hours = 1 week) |

Android has no such setting: the APK just sits on a local download page and you
install it whenever you like — there is no automatic pull step.

Change it (hours):

```bash
gh variable set VCP_SERVER_INTERVAL_H --repo homuraLan/vcp-cicd --body "24"     # daily
gh variable set VCP_CHAT_INTERVAL_H --repo homuraLan/vcp-cicd --body "72"       # every 3 days
```

`0` disables automatic pulls for that component; only manual triggers will deploy.
Manually running the deploy-sync workflow ignores the interval and syncs immediately —
useful when you want to verify a fresh build right away.

Version numbers follow the latest upstream tag: `v1.13.0` for the server, `v1.1.6`
for mobile.

Desktop is the exception: VCPChat has no version tags, and its `package.json` has
said `1.0.0` forever, so the upstream commit date is used instead — e.g. `v2026.10.25`.

When one release covers several components, the tag carries each version, e.g.
`v1.13.0.1.1.6.2026.10.25`.

</details>

<details>
<summary><b>Can the Linux binary just run?</b></summary>

Yes. It contains the full application directory (source + `node_modules` + `pydeps` +
plugin dependencies + compiled native modules) targeting the `node:20-alpine` musl
runtime.

Rust sub-projects used by plugins (DailyNoteSearcher and others) are compiled during
the build; upstream only ships prebuilt binaries for some platforms, and CI fills in
the missing one.

</details>

<details>
<summary><b>Why does this Release only contain the APK?</b></summary>

Because only VCPMobile's upstream changed this round. Builds are on-demand — only
changed components are compiled.

For components that didn't change, the summary links to the release where that
component was **actually built**, never to a release that lacks it.

</details>

<details>
<summary><b>Linux binary won't start / glibc error</b></summary>

The archive is built against Alpine (musl), matching the upstream Dockerfile. On glibc
systems (Debian, Ubuntu, CentOS, …) it may miss libraries or fail to load native modules.

Use the container image on glibc systems:

```bash
docker pull homuralan/vcptoolbox:latest
```

Alternatively, install `gcompat` and run it in a musl environment.

</details>

<details>
<summary><b>Are these builds safe?</b></summary>

All code comes from the three upstream repos above. This project only compiles and
packages it — no business logic is modified. Builds run on GitHub Actions and the
workflow files are public.

The only change: the server address is compiled into the app as a default, so you
don't have to configure it on first launch.

</details>

---

<p align="center">
  <sub>Unofficial builds · Upstream: <a href="https://github.com/lioensky/VCPToolBox">VCPToolBox</a> · <a href="https://github.com/MRiecy/VCPMobile">VCPMobile</a> · <a href="https://github.com/lioensky/VCPChat">VCPChat</a></sub>
</p>
