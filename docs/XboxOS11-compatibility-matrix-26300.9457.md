# XboxOS11 Compatibility Matrix (26300.9457 / 26H2)

Generated (UTC): 10/14/2026 10:39:25 PM
Source: `C:\XboxOS\Logs\DISM-Compatibility-20261014-2.json`
AppX identities: 47; Features: 136

## Summary

| Status | Count |
|---|---|
| present | 1 |
| absent | 4 |
| protected | 1 |
| eligible | 7 |
| alreadyDisabled | 4 |
| ambiguous | 0 |
| conflicting | 0 |

## Rows

| Kind | Candidate | Status | Feature/Matches | State | Detail |
|---|---|---|---|---|---|
| AppX | Clipchamp | Eligible | Clipchamp.Clipchamp_4.5.10920.0_neutral_~_yxz26nhyzhsrt | - | Present, unprotected, and enabled for consideration after explicit review. |
| AppX | Copilot | Absent | - | - | No provisioned AppX identity matched the candidate patterns. |
| AppX | TeamsConsumer | Eligible | MSTeams_1.0.0.1_x64__8wekyb3d8bbwe | - | Present, unprotected, and enabled for consideration after explicit review. |
| AppX | News | Eligible | Microsoft.BingNews_4.11.6001.0_neutral_~_8wekyb3d8bbwe | - | Present, unprotected, and enabled for consideration after explicit review. |
| AppX | Weather | Eligible | Microsoft.BingWeather_4.54.63038.0_neutral_~_8wekyb3d8bbwe | - | Present, unprotected, and enabled for consideration after explicit review. |
| AppX | Solitaire | Eligible | Microsoft.MicrosoftSolitaireCollection_4.25.4290.0_neutral_~_8wekyb3d8bbwe | - | Present, unprotected, and enabled for consideration after explicit review. |
| AppX | OutlookConsumer | Eligible | Microsoft.OutlookForWindows_1.0.0.0_neutral__8wekyb3d8bbwe; Microsoft.MicrosoftOfficeHub_19.2506.56051.0_neutral_~_8wekyb3d8bbwe | - | Present, unprotected, and enabled for consideration after explicit review. |
| AppX | GetHelp | Present | Microsoft.GetHelp_10.2407.40222.0_neutral_~_8wekyb3d8bbwe | - | Present in inventory but candidate is disabled in remove-apps manifest. |
| AppX | Tips | Absent | - | - | No provisioned AppX identity matched the candidate patterns. |
| AppX | XboxTCUI | Protected | Microsoft.Xbox.TCUI_1.23.28005.0_neutral_~_8wekyb3d8bbwe | - | Matched identities are protected; removal is not authorized from package-name prefixes alone. |
| Feature | XpsViewer | Absent | Xps-Foundation-Xps-Viewer | - | Feature not present in inventory. |
| Feature | PrintingXPS | AlreadyDisabled | Printing-XPSServices-Features | Disabled | Configured disable candidate is already satisfied; future servicing should skip this feature. |
| Feature | Smb1 | AlreadyDisabled | SMB1Protocol | Disabled | Configured disable candidate is already satisfied; future servicing should skip this feature. |
| Feature | Smb1 | AlreadyDisabled | SMB1Protocol-Client | Disabled | Configured disable candidate is already satisfied; future servicing should skip this feature. |
| Feature | Smb1 | AlreadyDisabled | SMB1Protocol-Server | Disabled | Configured disable candidate is already satisfied; future servicing should skip this feature. |
| Feature | WorkFolders | Eligible | WorkFolders-Client | Enabled | Present, enabled, unprotected, and actionable for a future disable operation after explicit review. |
| Feature | FaxAndScan | Absent | FaxServicesClientPackage | - | Feature not present in inventory. |

## Notes

- Read-only analysis only. No package removal or feature disable is authorized by this matrix.
- Eligible (features) means present, currently Enabled, unprotected, and enabled in the manifest — actionable later.
- AlreadyDisabled means the disable candidate is already satisfied (Disabled / Disabled with Payload Removed); skip in future servicing.
- Ambiguous prefix matches are rejected and never treated as authorized removals.

