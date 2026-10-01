# Strongbox interfaces for a macOS mirror app

Investigated on 2026-10-01. Scope: discover Strongbox Sync databases and copy their newest encrypted local backup without unlocking a database or handling credentials. No live Strongbox interface was invoked and no Strongbox files were changed.

## Finding

No documented, supported third-party interface meeting this scope was found in Strongbox's website, support knowledge base or published source. This is a search result, not proof that no interface exists. The practical candidate remains user-authorized filesystem access to local backups plus Strongbox's internal database metadata.

Strongbox explicitly says Sync is available only through Strongbox, with no visible cloud file for other apps or platforms. Export produces a separate disconnected copy. The service uses CloudKit and keeps encrypted database files in their normal database format. [Strongbox Sync FAQ](https://strongbox.reamaze.com/kb/sync/strongbox-sync)

## Supported user operations

- Strongbox documents the macOS backup root as `~/Library/Group Containers/group.strongbox.mac.mcguill/backups`. Backups are enabled by default and rolling retention is configurable. [Backup location](https://strongbox.reamaze.com/kb/security-and-privacy/where-are-strongbox-local-backups-stored-on-my-mac)
- Backups are exact copies of the database in its encrypted original format. Users can view and export them through Database Manager, Properties, Backups. Strongbox explicitly warns that filesystem locations can change. Backup creation is described as occurring before an edit is saved and when a new remote version is fetched. Thus a local backup timestamp alone cannot certify the latest CloudKit state. Scheduled Export is an iOS reminder feature, not a documented macOS automation API. [Backup behavior](https://strongbox.reamaze.com/kb/faqs/does-strongbox-store-backups-how-can-i-export-them)
- The documented `strongbox` URL scheme identifies the app. Its documentation gives no database-list or encrypted-export operation. [URL scheme and bundle IDs](https://strongbox.reamaze.com/kb/faqs/what-is-strongboxs-url-scheme-and-bundle-id)

## Published source and newer MCP uncertainty

The public repository HEAD inspected was `c70fc7b021d9dfa2b18a6d7e13406e717dd5251a`, committed 2026-07-17 with subject `1.65.0`. Source searches found no MCP implementation, database-export App Intent or scripting dictionary. The repository warns that it omits build resources and is provided for inspection. Therefore its lack of MCP code cannot establish the capabilities of a newer installed release. [Inspected revision](https://github.com/strongbox-password-safe/Strongbox/commit/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a), [repository scope](https://github.com/strongbox-password-safe/Strongbox#licensing--building)

Searches for MCP on `strongboxsafe.com` and `strongbox.reamaze.com` found no official tool reference. A search lead concerning release 1.65.1 is insufficient to verify whether its MCP can enumerate storage providers or export an encrypted database without unlocking. Those capabilities remain unknown. Do not assume that a credential-oriented MCP replaces the filesystem adapter.

The existing browser-autofill protocol does return database UUIDs and nicknames in its status response without consulting unlocked models. Its summary lacks storage-provider and backup-path fields, and its request dispatcher contains no encrypted-database export operation. Search and credential operations use unlocked databases. These are observations of 1.65.0 implementation code, not a compatibility promise for third-party backup apps. [Request handler](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/macbox/autofill-proxy/AutoFIllRequestHandler.swift), [database summary](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/macbox/autofill-proxy/DatabaseSummary.swift)

## Internal mapping and maintenance risk

At the inspected revision:

- `DatabasesManager` stores an NSKeyedArchiver array under `databases` in shared app-group preferences. [Persistence](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/macbox/Model/DatabasesManager.m)
- `DatabaseMetadata` archives `uuid`, `nickName`, `fileUrl` and provider information. Its backup directory is the backup root plus `uuid`. Read `nickName` for the human-facing label. The filename encoded in `fileUrl` is a separate value and must not be treated as the display name or durable identity. [Metadata](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/macbox/MacBox/DatabaseMetadata.m)
- `CloudKitStorageProvider` uses provider `kCloudKit` and constructs a Strongbox cloud URL from the filename, with the local database UUID in its query. This supports filtering Strongbox Sync sources without touching database contents. [CloudKit provider](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/model/cloudkit/CloudKitStorageProvider.swift)
- `BackupsManager` writes timestamp-named `.bak` files and sorts backups by filesystem creation date descending. [Backup implementation](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/StrongBox/BackupsManager.m)

These details are sufficient to build a version-specific adapter and fixture tests. They do not guarantee future class names, archive layout, provider encoding, UUID stability or paths. Revalidate mappings on every scan, key selections by UUID, and stop copying on missing or ambiguous identities. Preserve existing destination copies. Show unknown metadata formats as an actionable error.

## Remaining decisions

The sandbox probe must prove that a user can grant durable read access to both backups and metadata, including after restart and in the intended background process. Filesystem feasibility does not establish App Store acceptance. A supported automation route remains preferable if official documentation or vendor confirmation later establishes a password-free encrypted-export interface. No vendor contact has been made.
