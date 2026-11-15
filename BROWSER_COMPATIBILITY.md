# Browser compatibility audit — 13 November 2026

Scope: the web task manager and its embedded-browser flows. Fixes are deployed at https://tasks.molotilka.site/.

## Findings and fixes

1. Native prompt/confirm calls were previously replaced with app dialogs for member creation, recovery and task cancellation. A source scan confirms no prompt(), confirm() or alert() calls remain.
2. Toast notifications lived outside the modal dialog. They could be covered by the dialog’s top layer. `notice()` now places the message inside an open dialog, next to its heading, while preserving input values. Outside dialogs it uses the existing toast.
3. API handling assumed every response was JSON and exposed parsing/network errors to users. Shared `requestJson()` now gives readable messages for network failures and non-JSON gateway responses. File uploads use the same transport handling.
4. Expired-session responses now explain how to sign in again. Signing out when the session is already expired returns to login. Network failures during logout are still reported, rather than claiming a successful logout. Startup service failures no longer silently look like ordinary login requirements.
5. Request identifiers previously depended solely on crypto.randomUUID(). `newRequestId()` falls back to a UUID v4 generated with crypto.getRandomValues(), preserving secure randomness and server-compatible formatting. There is no Math.random() fallback.
6. Theme initialization now tolerates a missing matchMedia and supports MediaQueryList.addListener when addEventListener is unavailable. Existing localStorage try/catch handling remains intact.

## Verification

- `node scripts/checks/browser-compatibility.mjs`: passed. Checks secure UUID fallback/format/uniqueness, missing secure randomness, modern and legacy theme listeners, valid JSON, network failures and HTML gateway responses.
- In-app browser, isolated local fixture: app starts with randomUUID unavailable, localStorage blocked and the modern media-query event method unavailable.
- Simulated HTML 502, disconnected socket and expired session: the message appears inside the result form; entered text remains present. Logout from an expired session reaches the sign-in screen.
- Synthetic file selected through the file chooser and submitted to the local fixture: success, including fallback request-ID validation. No real user file or production task was uploaded/modified.
- Clipboard API unavailable: Copy link selects the invitation text and displays the manual-copy instruction. The invitation is an explicitly synthetic local fixture code, not a production credential.
- Production smoke check: health endpoint succeeds; deployed browser.mjs matches the workspace copy; the Create task dialog opens and closes successfully in the in-app browser. No production form was submitted.

The fixture script is `scripts/checks/review-flow-preview.mjs`. Test modes use local URL parameters `compat=restricted`, `compat=clipboard`, and `fault=html|network|expired`. The fixture does not connect to the database or send email/Telegram messages. The local preview server is stopped after testing.

## Limits

This is not certification of every browser/device. Physical iOS/Android Telegram webviews, old browser engines, camera capture, OS-specific download/save dialogs, blocked third-party fonts and real clipboard permissions on every device were not exhaustively tested. The legacy API cases above are controlled simulations in the available in-app browser. The file-upload test verifies the client path against an isolated API fixture; it is not a new end-to-end production Storage test.

Browser login uses corporate email/password; Telegram automatic login only applies when the app receives valid Telegram Mini App launch data. Separate browsers/webviews may have separate cookie sessions by design.

References used for capability semantics: [crypto.randomUUID](https://developer.mozilla.org/en-US/docs/Web/API/Crypto/randomUUID), [MediaQueryList.addListener](https://developer.mozilla.org/en-US/docs/Web/API/MediaQueryList/addListener), [dialog.showModal and the top layer](https://developer.mozilla.org/en-US/docs/Web/API/HTMLDialogElement/showModal).

Evidence: `.local/browser-audit/inline-service-error.jpg`, `clipboard-fallback.jpg`, `production-form.jpg`.
