# Google Drive discovery from the local copy path

Investigated on 2026-10-03 for the requested automatic Drive setup. This research uses official Google and Apple documentation. It did not inspect any user's Drive folders, credentials or database files and did not contact Google with account credentials.

## What the selected local URL tells us

For streaming on macOS 12.1 and later, Drive for desktop uses Apple's File Provider. Google documents the default parent location as `~/Library/CloudStorage`. Legacy streaming defaults to `/Volumes/GoogleDrive` and allows a different location. These are locations, not a documented contract for the child directory's account identifier. [Google's macOS integration guide](https://support.google.com/drive/answer/12178485?hl=en)

Google's English instructions call the Finder sections `My Drive` and `Shared drives`. German instructions call them `Meine Ablage` and `Geteilte Ablagen`. These pages do not specify whether the labels are literal filesystem components or localized Finder display names. They do not establish `MyDrive` without a space as a URL component. [English navigation instructions](https://support.google.com/drive/answer/10838124?hl=en), [German navigation instructions](https://support.google.com/drive/answer/10838124?hl=de)

The reviewed official documentation does not publish `GoogleDrive-<email>` as a stable basename format. A parser may recognize that convention, but should describe it as a supported convention rather than a guaranteed Google interface. Treat its email as a hint, require an exact account-label match, and verify the remote path. Do not accept an arbitrary directory simply because its name contains `GoogleDrive` or an email address.

Mirroring permits a user-selected local My Drive directory. Shared drives can only be streamed. Switching between mirroring and streaming changes the local path, and the formerly mirrored folder stops syncing. Consequently, an arbitrary mirrored path alone cannot identify its Drive account or its remote root. Keep the existing manual folder link for these cases. [Streaming and mirroring](https://support.google.com/drive/answer/13401938?hl=en)

## Why File Provider identifiers do not solve this

Apple provides `NSFileProviderManager.getIdentifierForUserVisibleFile(at:completionHandler:)`. Its documentation describes identifier and domain lookup for an item managed by the caller's File Provider extension and reports an error otherwise. It does not promise a bridge from another vendor's URL to a Google Drive REST ID. Apple's item identifiers are not documented as Google's file IDs. Do not add this framework or parse provider-private identifiers for this change. [Apple URL-to-identifier API](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getidentifierforuservisiblefile(at:completionhandler:))

## Minimal automatic mapping

This is an implementation recommendation, not a promise of Google's local path format:

1. Use only the already selected local target URL. Do not enumerate other local cloud roots, inspect Drive's private databases or expand filesystem permissions.
2. Accept an explicit, bounded File Provider path convention under `/Users/<user>/Library/CloudStorage` in the already selected, accessible target URL, with an account component matching a connected account and a recognized My Drive component. Preserve the remaining exact folder-name components. Unknown roots, shared drives, custom mirroring and aliases whose original mapping is unavailable use the existing manual link.
3. Resolve the connected account's My Drive root through the REST `root` alias. Traverse each remaining component within its previously resolved parent. Require one complete, unambiguous folder result per component. Google defines folders by MIME type and supports `root` wherever a file ID is accepted. [Folder API guide](https://developers.google.com/workspace/drive/api/guides/folder)
4. Persist the verified remote folder ID with the account and existing local-target identity. Invalidate or re-resolve an automatic association when the local target or account changes. Verification continues to find the filename inside that folder, so replacement file IDs do not require a new selection.

Use `files.list` with an exact query such as `'<parent ID>' in parents and name = '<component>' and trashed = false`. Escape apostrophes and backslashes before URL encoding. Request only folder metadata and pagination fields. Check the MIME type after parsing, and fail rather than follow shortcuts silently. Drive shortcuts have a distinct MIME type and target ID; supporting their local presentation would require a separate mapping decision. [Search syntax](https://developers.google.com/workspace/drive/api/guides/search-files), [Shortcut metadata](https://developers.google.com/workspace/drive/api/guides/shortcuts)

Remote folder names are not unique within a parent. Two same-named folders at any level make the path ambiguous, even if only one currently contains a matching database. Do not choose the first result or use the file's checksum to choose its future sync destination. File metadata exposes parent IDs, size and binary checksums; those checksums establish a content match, not an intended destination. [File metadata reference](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)

Follow every `nextPageToken`, including empty continued pages. Reject `incompleteSearch`, malformed metadata, repeated tokens and bounded pagination exhaustion. The existing request policy uses `spaces=drive` and the default user corpus. A rejected token or concurrent additions can invalidate a traversal; retry from a fresh request or leave the association unresolved. [List response and corpus semantics](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)

## Identical files elsewhere

Path resolution does not need a broad filename search. A same-named, identical file in another folder never changes the selected destination or blocks verification. To produce the requested informational notice, an additional metadata-only exact-name search in the selected account can compare size and the existing SHA256/MD5 fingerprint, exclude the selected folder, and count distinct file IDs with a validated match. Never download file contents for this notice.

This notice is best-effort. A failed, incomplete or bounded search must not become a verification failure or imply that no duplicates exist. Say that additional matches were found when confirmed; do not claim an exhaustive global Drive inventory. A successful search refers to the selected account's accessible corpus, not every account or inaccessible shared drive. The existing `drive.metadata.readonly` scope permits metadata listing; no new content scope is needed. [List authorization and search coverage](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)

Multiple same-named files inside the intended folder remain a verification ambiguity. The advisory search must not suppress that error, choose a different copy elsewhere, or change the persisted folder association.

## Evidence still required

Synthetic tests can prove exact parsing, account matching, parent traversal, pagination, ambiguity and advisory-only duplicate handling. They cannot prove the assumed local basename and My Drive URL component on a real Google Drive for desktop installation. The prepared Google setup and explicitly authorized real-provider acceptance pass remain necessary. This change does not start the postponed complete acceptance test in issue #16.
