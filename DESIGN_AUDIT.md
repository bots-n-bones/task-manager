# BnB Task Manager — design audit

Date: 13 November 2026. Result: partial compliance; full compliance is not established.

## Reference and method

Reference: `../design-system/site/` (the BnB design-system handbook), checked against `/docker/design-system/site` on the production VPS. SHA-256 hashes match for colors.css, spacing.css, typography.css, Button.jsx, Input.jsx and icons-roles.card.html. The local `type-roles.css` is an additional local resource, absent on the production handbook; findings below use the published guidelines and component examples, not that file alone.

The published task-manager stylesheet matches `web/style.css` byte for byte. Compared source rules, tokens, component definitions and browser-computed styles. Inspected the task list, cancelled tasks, projects, members, task details, creation form and empty state. Inspected light/night themes and a narrow viewport (actual measured CSS width 354px; viewport override requested 390×844). No horizontal overflow was observed in the narrow list or creation form. Restored the original Auto theme, viewport and Cancelled screen after inspection.

Login, password setup/recovery, invitations, file submission, destructive confirmation and error paths were reviewed in source only. No credentials, tasks, memberships or permissions were changed. No production code changes or deployment were made in this audit.

## Confirmed matches

- Five token files are byte-identical to the handbook: colors, spacing, typography, motion and base.
- Both theme palettes and semantic surface/text/accent aliases match. Light canvas #f6f6f7 and night canvas #131312 are applied.
- Main page heading on desktop: IBM Plex Sans, 32px / 1.17, weight 500.
- Card titles: IBM Plex Sans, 15px, weight 500. Body: 14px / 1.5. Metadata: IBM Plex Mono, 11px / 1.5.
- Primary CTA default: 13px, weight 500, padding 10px 20px, radius 12px, matching Button.jsx and the empty-state CTA example. The buttons showcase uses a different compact primary size; these two reference examples should not be conflated.
- Shared fields use the expected 4px radius, 8px 10px base padding and hairline inset ring.
- Cards/dialogs use the 12px radius; top bar uses the 56px height token; light/night logo treatment matches.
- Status tags use the expected 10px mono size, 4px radius and 3px 8px padding; running/done/error colors use the corresponding aliases.
- Dialog opening uses bnb-in and reduced-motion disables it.

## Confirmed deviations

| ID | Area | Actual implementation | Handbook reference / target |
| --- | --- | --- | --- |
| D1 | Parameter fields | `web/style.css:195`: inputs/selects/textareas use IBM Plex Sans 14px (16px on narrow screens), tracking normal. Confirmed in the creation form. | `components/forms/Input.jsx` and `inputs.card.html`: parameter/search input uses IBM Plex Mono 12px, tracking -0.01em. Apply that role to parameter controls; explicitly document any separate body-text/editor variant and mobile sizing adaptation. |
| D2 | Section label | `web/style.css:94`: TEAM uses IBM Plex Mono 10px, tracking .12em. | `guidelines/type-label.card.html`: section label is JetBrains Mono 11px, tracking .3em, uppercase. |
| D3 | Tracking | Body, labels, metadata and status tags compute to normal letter spacing. | Handbook component bodies use .012em for sans and -0.01em for mono. Missing in `:root`, `.task small`, `.status`, `label`, etc. |
| D4 | Button hover/press | `.primary:hover` brightness 1.08; no primary pressed state. | `Button.jsx`: hover 1.04, pressed .96. |
| D5 | Secondary and quiet buttons | Generic secondary actions use white/card background, 4px radius, hairline ring; quiet buttons inherit sans 13px and 8px 12px padding. | `Button.jsx`: outline = transparent, 12px radius, .5px ink ring, 8px 16px; ghost = mono 12px, -0.01em, 6px 12px. Components are not assigned these variants consistently. |
| D6 | Focus, disabled and loading | Global focus is a 2px accent outline, offset 2px. Every disabled button uses cursor wait. Async actions only dim/disable their button. Field error states are messages rather than a field error ring. | Handbook button/input showcase: 1.5px muted focus ring, input focus 1px inset ink ring, input error 1px inset error ring; disabled button cursor not-allowed; loading is a distinct state with pulse icon. |
| D7 | Checkboxes | `web/style.css:233` uses native checkbox rendering with accent-color. | `components/forms/Checkbox.jsx`: explicit 16×16 control, 4px radius, hairline/checked fill and a 12px SVG tick. Native appearance varies by browser. |
| D8 | Empty state | A single 14px sans sentence inside a dashed rectangle. Confirmed in the filtered task list. | `guidelines/type-label.card.html` and `components/editor/empty-state.card.html`: 14px JetBrains Mono uppercase title at .3em tracking, separate body text. Task-specific copy may differ; the type hierarchy is missing. |
| D9 | New chevrons | `web/app.js:59`: 16×16 viewBox, path M4 6l4 4 4-4, stroke 1.5. | `guidelines/icons-roles.card.html`: reference down/unfold glyph has 20×20 viewBox, 16px rendered size, path M5 8l5 4 5-4, stroke 1.4. Both have rounded caps/joins. The handbook has no dedicated select component, so this is an icon-family mismatch, not evidence of a broken select. |
| D10 | Font delivery | `web/tokens/fonts.css` imports Google Fonts. | Handbook `tokens/fonts.css` uses bundled WOFF2 @font-face files. Font family names match, delivery implementation does not. |

## Product adaptations requiring a documented decision

These are not automatically defects: the handbook is largely for a node editor and does not provide task-manager-specific screen designs.

- Sidebar width 232px, desktop content padding 36/32/72px and mobile breakpoints 720/400px are application layout choices without a matching reference screen.
- Sidebar action radius 6px, mobile page-title size 26px and dialog title size 20px are not standard typography/radius roles in the imported tokens. Specify them as intentional product extensions or use existing roles.
- Task statuses add dots and review/cancelled semantics not defined as task statuses in the node-run handbook. Review uses sage; overdue cards add a 7% error tint. Existing semantic colors are reused, but these task-specific variants need documentation.
- Native date picker, file chooser, browser prompt/confirm and validation messages are platform-rendered. Their complete visual identity cannot be guaranteed by the existing app CSS.
- Wire/node/canvas/palette components in the handbook do not apply to this task manager; their absence is not noncompliance.

## Limits and conclusion

The foundation is BnB, but importing identical tokens does not establish component compliance. Ten groups of concrete deviations are recorded above. No numeric compliance percentage is justified: there is no authoritative complete task-manager design or exhaustive acceptance checklist.

This audit does not certify all browsers, every device width, native Telegram Mini App rendering, all authentication states, or all error/loading paths. A follow-up implementation should resolve D1–D10, document product adaptations and then repeat visual verification of the affected states.

Screenshots: `.local/design-audit/` — form-light.jpg, tasks-night.jpg, mobile-night.jpg, mobile-form-light.jpg, task-details-light.jpg, empty-state-light.jpg. `projects-light.jpg` was captured during navigation and is not relied on as evidence of loaded project cards.
