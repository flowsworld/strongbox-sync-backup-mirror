# Automatic Drive path checks

Verified on 2026-10-03, macOS 27.0.1 build 26A434, Apple Silicon,
Xcode 27 and Swift 6.4. Source revision `0cdcb31` is based on merged
`2988d43424d932170f62192a8d40a585bcb28fbd`.

Flo selected automatic account and relative-path matching for the already
selected local Drive target. No file picker or confirmation is required for
an unambiguous mapping. The revised static states are published at
https://pages.diesis.cloud/d/1hss1khbf5yu. Unknown or ambiguous mappings retain
the existing manual folder-link/ID setup on the approved Drive A page.

## Results

- All 244 Swift test functions passed: 101 core Swift Testing, 106 app Swift
  Testing and 37 XCTest functions. Parameterized cases are additional cases,
  not counted as separate functions.
- All 116 Python tests passed. Syntax checks passed for ten zsh scripts and
  the Google setup bash script. English and German catalogs pass plist validation.
- Universal development candidate 0.2.1 build 2026100303 passed packaging,
  ZIP checksum and strict ad-hoc signature verification. Both arm64 and x86_64
  slices declare macOS 13.0. A three-second detached demo launch passed while
  the entire `.build` directory was unavailable. The owned process was stopped
  and build resources restored.

The new tests cover recognized and unsupported local layouts, exact remote
parent/name traversal, paginated ambiguity and incomplete results, bounded
searches, matching account ownership through the real request policy,
size/checksum-only advisory matching, automatic setup without folder selection,
persisted opt-out, manual overrides, changed local destinations, immediate
retry, stale/cancelled discovery and shutdown ownership. A two-database fixture
confirms that a suspended advisory lookup cannot delay the other primary check.

All provider responses, credentials and files were synthetic. The actual HTTPS
transport and user Keychain were not used. The integration fixture initially
failed with `disallowedRequest`; adding the explicit folder-only metadata fields
to the existing request allowlist made the same test pass. No content-download
or mutation endpoint was added.

## Reviews

Two independent reviewers assessed Standards and Spec against the fixed main
revision. Both report no remaining findings after verified corrections.

The Standards review found silently discarded advisory failures and inaccurate
query-scope wording. Advisory failures now log fixed diagnostic text without raw
provider errors; primary verification stays successful. English/German UI copy,
setup instructions and research disclose the additional same-name metadata search
outside the selected folder.

The Spec review found advisory work delaying later primary checks and an unavailable
immediate retry after automatic setup failed. Primary checks now precede all advisory
lookups, and unresolved eligible targets can request an immediate retry. Its proposed
current-home restriction was withdrawn: the user requested matching the explicitly
selected accessible target, not rejecting another readable home directory. The
research wording now matches that bounded parser. No additional local folders or
permissions are inspected.

## Limits and cleanup

Google does not publish a stable contract for the local `GoogleDrive-<email>`
root or literal My Drive component. Recognition is a supported convention,
verified against the connected account and exact remote folder hierarchy.
Custom mirrored paths, shared drives and unknown layouts use the manual fallback.
Actual Google Drive for desktop path recognition, OAuth, signed Keychain access
and real multi-account behavior still need the previously prepared provider
acceptance work. Cross-compilation is not an Intel or macOS 13 runtime test.

The complete acceptance pass in issue #16 remains explicitly postponed. No Google
project, real account, production signing, database, helper configuration, daily-use
target, login item or OS permission was changed. Only this task's worktree, builds,
processes and temporary logs may be removed after preserving this report.
