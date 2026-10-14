# Compatibility

## Why components are protected

Removing “unused” Windows packages often breaks Store installs, Xbox identity, Game Bar entry points, launcher webviews, or anti-cheat drivers. XboxOS11 therefore maintains an explicit allow/deny surface in `config/compatibility.json`.

### Protected categories

| Category | Why it stays |
|----------|--------------|
| Microsoft Store | Delivers Xbox app updates and many modern games |
| Xbox / Gaming Services | Required for Xbox mode and PC Xbox networking |
| Game Bar overlays | Entry points for Xbox mode (`Win+G`, `Win+F11`) |
| Windows Update | Security and cumulative servicing |
| Microsoft Defender | Security baseline; not disabled for benchmarks |
| DirectX / Media Foundation | Game rendering and cutscenes |
| WebView2 | Launcher and Xbox web content |
| .NET / VC++ surface | Native and managed game/launcher runtimes |
| Bluetooth / Audio / Networking | Controllers, chat, multiplayer |
| Windows Installer / Cryptography / Servicing | Installers, trust, component store health |
| Anti-cheat compatibility | Avoid weakening kernel/security expectations |

## Present offline vs installed later

| In offline image (when provisioned) | Typically post-install |
|-------------------------------------|------------------------|
| Store, Xbox packages, frameworks | AMD Adrenalin full stack |
| Optional features / drivers INF | Steam, Battle.net, EA, Ubisoft, Epic |
| Cumulative updates you inject | Game-specific redistributables |
| | Xbox app updates from Store |

## Xbox mode / Full Screen Experience

Research summary used by Milestone 1:

- Microsoft documents **Xbox mode** for Windows 11 24H2+ ([support article](https://support.microsoft.com/en-us/servicing/os/windows/docs/2025/10/windows-gaming-full-screen-experience)).
- Handhelds: Settings → Gaming → Xbox mode → choose home app; optional **Enter Xbox mode on startup**.
- Other PCs: enable Xbox mode; use Game Bar / Task View / `Win+F11`.
- OEM unattend setting `Microsoft-Windows-Gaming-Configuration` / `StartupToGamingHome` is documented on Microsoft Learn, with passes `offlineServicing`, `specialize`, `oobeSystem`.
- Desktop automatic startup is **not** assumed equivalent to handheld behavior.
- XboxOS11 will not claim Xbox mode works until validated on an installed system.

## Security defaults

- TPM required (Windows 11 baseline)
- Secure Boot expected for UEFI installs
- Defender remains enabled
- Virtualization-based protections are left at Windows defaults
- No benchmark-motivated security disablement

## Performance note

Reducing ISO size by removing consumer apps can reduce clutter, but it does **not** automatically improve frame rates. Performance work belongs in Milestone 4 with measurements on Ryzen 7 7800X3D + Radeon RX 9070 XT hardware.
