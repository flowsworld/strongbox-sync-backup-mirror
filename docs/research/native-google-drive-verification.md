# Native Google Drive verification

Investigated on 2026-10-02 for [issue #9](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/9), including its acceptance criteria and comments. No comments existed when inspected. This records research and an implementable design. It does not establish Google verification, working production credentials, App Store approval or actual provider validation.

The provider-neutral verification state machine is implemented in [UploadVerification.swift](../../macos-app/Sources/SyncCopiesCore/UploadVerification.swift), with [focused public-behavior tests](../../macos-app/Tests/SyncCopiesCoreTests/UploadVerificationTests.swift). It validates typed fingerprints and remote metadata, persists validated state, compares size and SHA256/MD5 and preserves the helper's warning accounting. The Drive search/parser, shipping OAuth client, signed Keychain integration, scheduling and setup interface need separate completion. Local copying must work without Google setup and must continue after every verification failure. The app verifies metadata; a separate sync client uploads the local copy.

## Read-only permissions and production distribution

Request only `https://www.googleapis.com/auth/drive.metadata.readonly`. Google classifies this as restricted, with access to file metadata across the user's Drive. Selecting a target folder limits the app's queries, not the OAuth permission. `drive.file` is non-sensitive but permits editing selected files and does not document automatic access to later replacement files created by another sync client. It cannot be assumed to preserve the required folder-and-filename discovery. Google's permitted restricted-scope categories include backup/sync, productivity/education and reporting/security. Whether this verification-only feature qualifies requires Google's determination. [Drive scopes and qualification](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

For public distribution, complete restricted-scope verification unless an applicable exception exists. Personal use and development/testing are exceptions, not approval for a paid public product. Google requires an annual security assessment when the app can access restricted data from or through a third-party server. Keeping all credentials and metadata on the Mac, with direct Google requests and no telemetry containing that data, appears to avoid that trigger. This is an inference about the proposed architecture, not an exemption issued by Google. Submit the actual data flow for Google's assessment. Prepare a scope justification and demonstration of every requested capability. [Restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)

Production preparation requires an owned Google Cloud project, Drive API enabled, an external Desktop app OAuth client, published branding and successful data-access verification. Google requires a public app homepage, a privacy policy on the homepage's domain, accurate contact details and authorized-domain ownership through Search Console. The privacy policy must describe metadata access, use, storage and sharing. Published branding precedes a data-access verification request. [Brand verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification), [desktop client setup](https://developers.google.com/identity/protocols/oauth2/native-app#prerequisites)

Use separate development and production projects, and a native project separate from the current helper. Do not ship a setup flow requiring every purchaser to create a Google Cloud project. A bundled Desktop client configuration identifies the application; it is not a confidential server secret. Google's desktop documentation explicitly describes installed clients as unable to keep `client_secret` confidential and marks it optional in code and refresh exchanges. Never confuse that configuration with a user's refresh token. [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)

An external project in Testing issues refresh tokens that expire after seven days for this Drive scope. Production tokens can also stop working after revocation, inactivity or token-count limits. Tests and recovery must handle expiration; Testing is unsuitable for unattended public use. [Refresh-token expiration](https://developers.google.com/identity/protocols/oauth2#expiration)

## Desktop authorization and account lifecycle

Google continues to support loopback IP redirects for Desktop app clients. The mobile/Chrome loopback deprecation does not remove desktop support. [Loopback migration guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration)

Proposed authorization flow:

1. Start only after the user chooses to connect. Create fresh cryptographic `state` and PKCE verifier values. Bind a listener to `127.0.0.1` on an ephemeral port before opening the browser. Use a fixed callback path, for example `/oauth2/callback`.
2. Open the system browser at `https://accounts.google.com/o/oauth2/v2/auth` with `response_type=code`, the Desktop client ID, exact redirect URI, the metadata scope, `code_challenge_method=S256`, PKCE challenge, state and `access_type=offline`. Request fresh consent when a refresh token is needed. Google's authorization endpoint rejects embedded user agents such as `WKWebView`. [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
3. Accept only the expected path and a single state that equals this live attempt. Require exactly one code or one denial. Reject duplicate parameters, wrong state, arbitrary paths, absolute-form targets and completed/replayed callbacks. Bound headers and request size. Return fixed text with `Cache-Control: no-store`; never echo callback values. Close the listener on completion, cancellation or a five-minute deadline. These bounds preserve the existing helper's setup behavior. [Existing setup](../../google_drive_setup.py)
4. Exchange the code at `https://oauth2.googleapis.com/token`, with the same redirect URI and PKCE verifier. Validate the response before storing it, including the exact granted scope set when supplied, a nonempty refresh token and bounded token strings. Keep verifier, state and access token in memory. Native OAuth best practice requires an external user agent and PKCE, and treats a shared native client secret as public-client configuration. [RFC 8252, sections 4, 7.3, 8.1 and 8.5](https://www.rfc-editor.org/rfc/rfc8252)
5. Read the account label and selected folder before committing setup. `about.get` accepts the metadata scope and a fields mask. Use `fields=user(emailAddress)` as in the helper; no profile or OpenID scope is needed for this label. [About endpoint](https://developers.google.com/workspace/drive/api/reference/rest/v3/about/get), [existing provider](../../google_drive.py)
6. Persist a new credential item first, then atomically save settings referring to it. If settings fail, keep the previous credential/settings pair intact and remove the staged item. Remove an obsolete item only after the new pair is saved. A cancelled attempt must leave the previous setup unchanged. Record cleanup failure without publishing credentials in diagnostics. [Existing pair rollback](../../google_drive_setup.py)

Distinguish disabling checks, removing the native app's local credentials, and revoking the Google grant. Local removal must work offline. A revocation action posts the token in a form body to `https://oauth2.googleapis.com/revoke`; this is an authorization change, not a Drive-file write. Google states revocation invalidates granted scopes and issued tokens across all clients in the project, so reusing the helper's project can break the helper. Do not perform revocation implicitly during cancellation or staged-item cleanup. On revocation failure, show that checks have stopped locally but Google access may remain, with a way to retry or remove access in Google Account settings. [Token revocation](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke)

## Keychain and sandbox

Use Security.framework's `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate` and `SecItemDelete`. Apple recommends the SecItem API and data protection Keychain for new code. It is available in a user login context and uses entitlement-based access groups. Those entitlements require a provisioning profile. The existing ad-hoc build does not establish that a production Keychain identity is configured. Tests should inject a credential store rather than use a real user Keychain. [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

Proposed native item attributes:

- Generic password class, a new service such as `cloud.diesis.sync-copies.google-drive`, and a random opaque account identifier referenced by settings.
- `kSecUseDataProtectionKeychain=true` consistently on add, read, update and delete. Apple recommends this key for macOS access-group and accessibility behavior. [Data protection Keychain key](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- `kSecAttrSynchronizable=false`. Do not synchronize refresh tokens through iCloud.
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` as a candidate for background operation and device-local storage. Apple documents accessibility after the first unlock and no migration to another device. Verify actual macOS lock, wake and reboot behavior in a signed build rather than infer it from the attribute name. [Accessibility attribute](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- The app's private default access group. Shared access requires correctly signed group entitlements. Do not add the helper's service or search its existing item. [Keychain access groups](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)

Translate missing items, locked/unavailable access, denied interaction, invalid data and entitlement errors into typed app errors. Do not treat every Keychain failure as a missing account or erase existing settings after a transient failure. Keychain lookup blocks its calling thread; run it away from the main actor. [SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))

The current [entitlements](../../macos-app/entitlements.plist) grant sandboxed filesystem access but no network capability. Add `com.apple.security.network.client` for outbound HTTPS. Add `com.apple.security.network.server` only when the chosen browser authorization adapter needs its loopback listener, bound exclusively to loopback and active only during sign-in. Apple documents these as connection-initiation permissions. Their presence alone does not prove that the signed callback works. Keep App Sandbox and user-selected file bookmarks. [Client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client), [server entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server)

## Exact provider behavior

The helper's contract is defined in [remote.py](../../remote.py), [google_drive.py](../../google_drive.py) and [tests/test_google_drive.py](../../tests/test_google_drive.py). The native design preserves the following application rules.

1. Validate folder IDs with the helper's `[A-Za-z0-9_-]{1,256}` allowlist. Treat `root` as the My Drive alias. Parse only recognized HTTPS `drive.google.com` folder/My Drive links or an explicit ID; do not fetch an arbitrary pasted URL.
2. On every check, request `files/{folderID}` with `fields=id,name,mimeType,trashed` and `supportsAllDrives=true`. Require a real folder, `trashed=false`, a valid returned ID and a bounded name. `root` can resolve to a different real ID; an explicit folder ID must match. A missing or inaccessible folder is an error, never "upload pending".
3. Search the resolved folder and exact target filename on every check. Build `q` from escaped values: `'<folderID>' in parents and name = '<filename>' and trashed = false`. Escape backslashes and quotes inside the query literal, then URL-encode parameters. These are distinct operations. Google documents exact-name and parent queries and escaping. [Search syntax](https://developers.google.com/workspace/drive/api/guides/search-files)
4. Request only `nextPageToken,incompleteSearch,files(id,name,parents,trashed,size,md5Checksum,sha256Checksum)`, `spaces=drive`, `pageSize=100`, `supportsAllDrives=true` and `includeItemsFromAllDrives=true`. Follow every page, including empty pages with a continuation token. A true `incompleteSearch` means some results may be absent. Reject it; reject repeated tokens and more than 100 pages. Google notes that page results can change and that rejected tokens require a fresh search. For helper parity, a rejected token fails this check and the next scheduled check starts fresh. [Files list](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)
5. Validate returned metadata against the exact name, parent and nontrashed status independently of the query. The helper requires a decimal-string size and validates each present digest as exact-length hexadecimal. Native decoding must also reject overflow and boolean/numeric coercion. A malformed weaker digest is still an invalid response even if SHA256 matches.
6. Accept zero matches as pending. Accept one validated match. Reject two matches, including matches on different pages. Persist a remote file ID only as diagnostic history; it is never the next lookup key. This handles deletion and recreation of Drive files.
7. Compare both size and the strongest supported available checksum, SHA256 before MD5. MD5 is a compatibility fallback, not an authenticity guarantee. If neither supported digest exists, return an error; do not confirm by size or modification time. Google documents MD5 for binary content and SHA256 only when available for stored file content, not Docs Editors or shortcuts. [File metadata](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)

Send metadata GETs only to fixed `https://www.googleapis.com/drive/v3/` operations. Token POSTs and explicit revocation have separately fixed endpoints. A `URLSession` delegate must reject redirects before sending credentials elsewhere. Use an ephemeral session, no cookies, no disk response cache, bounded response streaming up to the helper's 1 MiB limit, and safe error codes instead of raw URLs, response bodies or headers. No `alt=media`, exports, content downloads or file mutation operation belongs in the provider. These are proposed implementation restrictions based on the existing helper.

## Network readiness and retries

The helper gates each API attempt on up to 30 seconds of readiness checks. It checks route availability, then DNS/TCP/validated TLS at the actual endpoint with a credential-free HEAD request; it retries readiness every two seconds with an endpoint-probe timeout of at most three seconds. HTTP error responses still prove endpoint reachability. API requests have a 20-second timeout, at most four attempts and delays of 2, 4 and 8 seconds. It retries transport failures, HTTP 429 and HTTP 5xx. It does not retry malformed responses, redirects or HTTP 400/401/403/404. [Helper implementation and network tests](../../google_drive.py), [provider tests](../../tests/test_google_drive.py)

For the native adapter, use a route/path observation plus the same endpoint readiness proof. Path availability alone is insufficient. Inject both readiness and delay/clock behavior into tests. Cancel sign-in or check tasks on disable/account change, and never block local copying or the main actor while waiting. Reuse one credential actor per native account but do not serialize local copying behind its network work.

Google also documents HTTP 403 quota reasons such as `rateLimitExceeded` and `userRateLimitExceeded` as retryable with backoff, and HTTP 404 can mean missing read permission as well as nonexistent resources. Preserve the helper's bounded status-based retries first. A later reason-aware 403 retry policy needs explicit tests distinguishing quota from access denial. Never relabel every 403 as transient. [Drive errors](https://developers.google.com/workspace/drive/api/guides/handle-errors)

## State machine and local consistency

The behavior below comes from [upload_check.py](../../upload_check.py) and [its tests](../../tests/test_upload_check.py), not a Google cloud-freshness guarantee.

Use a pure transition function with an injected timestamp and warning threshold. The default threshold is 1,800 seconds. Store one state per selected database. Define the native verification context from provider, credential-reference/account generation, resolved folder, exact filename and local destination selection. Store the local SHA256 as content identity. The helper's context uses provider/folder/filename; the account and destination additions prevent reusing a native confirmation after account or destination changes.

Persist typed states `confirmed`, `pending`, `overdue` and `error`, plus context, local SHA256, checked timestamp, optional last-confirmed timestamp, nonnegative pending seconds, optional previous successful mismatch timestamp and optional remote ID. Disabled verification has no active result; it is separate from `pending`.

| Current observation | Transition |
| --- | --- |
| New content or changed context | Clear confirmation history and accumulated wait before applying the observation |
| Size and preferred supported checksum match | `confirmed`; pending seconds zero; mismatch timestamp absent; last confirmation is this check |
| Missing file or nonmatching valid metadata | Start at zero for new content; otherwise preserve pending seconds and add `min(900, max(0, now - previousMismatchAt))` only if the previous successful mismatch timestamp exists; store this mismatch timestamp |
| Successful mismatch reaches warning threshold | `overdue` |
| Provider, credentials, local-file or configuration failure | `error`; preserve same-content accumulated wait and confirmation history; clear the mismatch timestamp |
| Error before the context/content can be read | Preserve the last known context/content and wait, set `error`, clear the mismatch timestamp |
| Invalid saved state | Record a safe reset error once; replace invalid verification state; next check starts without the previous timer |

The first successful mismatch after an error adds no failed/offline interval. A long sleep adds at most 900 seconds between successful mismatch observations. Do not describe this as total elapsed upload time. Tests must cover short checks, backward wall-clock movement, sleep, restart and content/folder/account changes.

A historical confirmation can remain on the same-content error state for context, but the current status is `error`. It must never make the current check appear confirmed. On new content, even this historical confirmation clears. Save the new result before history or notification delivery. A failed notification cannot leave an earlier confirmed result as the stored current status.

Fingerprint the current local destination before querying Drive, with SHA256 and MD5 from one streaming read. Hold the security-scoped folder grant and descriptor through the check. Reject symlinks and nonregular files using the existing [descriptor-based file access](../../macos-app/Sources/SyncCopiesCore/FileIO.swift). After the provider responds, confirm the descriptor and anchored directory entry still refer to the same content. The helper accepts a ctime-only metadata change after rehashing unchanged content; changed inode/size/mtime or different content is an error. The native design must test path replacement as well as descriptor mutation. Reject an old result after the user changes setup or a newer local copy becomes current, using a generation captured at check start.

Local copying remains the first independent operation. A completed local copy remains successful even when verification fails. Network checks should not hold the destination's write lock for their duration; validate the anchored entry again before publishing instead. Later app integration must store and display local-copy state and cloud-check state separately.

## Notifications and persistence

Add four independent preferences for check errors, overdue uploads, recovery and confirmed cloud matches. Preserve local-copy preferences separately. Proposed defaults enable problems, with recovery and confirmation optional, matching the app's existing local-notification choices. Final wording and layout require Flo's static-mock selection.

Deduplicate errors by typed problem code and context, not timestamps or local content. Deduplicate overdue alerts while the same content/context stays overdue. A repeated confirmed check refreshes its timestamp without producing another success event. A first confirmation for new content is eligible for confirmation notification. A successful check after an error is eligible for recovery even when the file is still pending; do not call it a confirmed cloud match. A recovered-and-confirmed observation may carry both facts, but should produce a single chosen notification rather than two alerts.

Persist result changes before delivery. Persist failed delivery IDs for retry when delivery itself fails. Respect the existing native app rule that missing OS authorization does not accumulate old alerts for later delivery. The helper retries failed error/overdue notification delivery; native recovery and confirmation events need equivalent explicit delivery tests. Keep bounded history, safe typed messages and tokens outside settings/history. The existing helper's log and notification behavior is in [report](../../upload_check.py), and the native baseline is in [AppModel.swift](../../macos-app/Sources/SyncCopies/AppModel.swift).

## Implementation boundaries and tests

Keep verification in `SyncCopiesCore` independent of SwiftUI. Use small typed values for folder, metadata, fingerprint, context, result and failure code. Prefer ordered checksum values or an explicit SHA256/MD5 choice over reliance on dictionary iteration. Concrete core types can parse Drive folder links, build allowed request descriptions, validate paginated metadata and compute the state transition without real credentials or networking.

The operating-system boundary supplies a credential store, HTTPS transport, readiness checker, browser/callback handler, stable local fingerprint reader, atomic state store and notification delivery. Inject asynchronous functions where that suffices; avoid building a generic provider registry for one provider. The app coordinator owns opt-in, setup generations, scheduling and persistence. The UI presents the independent local and cloud results.

Automated tests must use synthetic metadata/files and a fake credential store. No test contacts Google or reads the helper's configuration. Cover:

- Exact folder resolution, `root`, folder access failure, recreated file IDs, quote/backslash names, duplicates across pages, empty continued pages, incomplete search, pagination cycles/limits and malformed sizes/digests.
- SHA256 precedence, MD5 fallback, wrong size, missing digest and no content-transfer or Drive mutation request.
- Wrong/repeated callback state, duplicate parameters, cancellation, timeout, missing refresh token, unexpected scopes and transactional setup failures.
- Redirect rejection, fixed endpoint restrictions, 1 MiB response cap, missing route, endpoint TLS/readiness failure, bounded retries, terminal access errors and cancellation.
- Every state transition above, including error after confirmation, error before hashing, same-content error recovery, new content during an error and state corruption.
- Descriptor and path replacement during a check, ctime-only unchanged-content updates, changed content, stale generation rejection and continued local copying during network failure.
- Independent notification selections, repeated unchanged confirmation, restart deduplication and persistence/delivery failures.

## Completion and remaining evidence

| Work | Can proceed without cloud/account changes or UI choice? | Completion evidence needed |
| --- | --- | --- |
| Provider-neutral typed metadata and state transitions | Implemented with synthetic public-behavior tests | Independent diff review and final full-suite run |
| Drive folder search/parser and request policy | Yes | Synthetic automated tests and independent diff review |
| HTTP/Keychain/browser adapters | Yes, as code with fake boundaries | Unit tests; signed OS integration remains separate |
| Public setup and notification UI | Static alternatives can be prepared | Flo chooses the published mocks before changing real components |
| Owned OAuth project and Desktop client | No account configuration has been inspected or changed | Named project owner, separate project IDs and configured clients |
| Google production verification | No | Published branding, accepted restricted-scope justification and any required assessment |
| Production Keychain and sandbox callback | No signing identity/profile has been established here | Correctly signed bundle, save/read/relaunch/delete, cancelled/failed setup, lock/wake/reboot and loopback callback tests |
| Actual Drive validation | Requires explicit authorization for that validation | Dated report identifying scope and synthetic cloud fixtures, with no database content download or Drive mutation |
| Full migration from helper | Outside #9 authorization | Separate migration/uninstall request after native verification works |

The account owner, project IDs, verification outcome and production signing configuration are unknown, not assumed missing. No real credentials were loaded, no Google account changes were made and no actual provider validation ran during this investigation or the synthetic core tests. Issue #9 remains open until setup, app integration, independent notifications and the required validation are complete. The completed core is partial preparation and is not wired into the running app.
