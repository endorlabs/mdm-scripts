# Why VS Code is configured via `product.json` and not an enterprise policy

VS Code ships an enterprise policy named `ExtensionGalleryServiceUrl`, and it looks like
exactly the right tool for pointing the extension gallery at the Endor Package Firewall: it
is delivered through the MDM channels this repo already uses, it survives VS Code updates,
and it cannot be edited by the developer.

We do not use it. This note records why, so the question does not have to be re-investigated
from scratch, and what would have to change for it to become viable.

Findings verified against the shipping **VS Code 1.131.0** bundle
(`Contents/Resources/app/out/vs/workbench/workbench.desktop.main.js`) and upstream source at
tags `release/1.99` and `main`.

## What the policy is, and where it reaches

`ExtensionGalleryServiceUrl` backs the hidden, application-scoped setting
`extensions.gallery.serviceUrl` and carries `minimumVersion: "1.99"`. Platform delivery is
genuinely broad:

| Platform | Mechanism | Available since |
|---|---|---|
| Windows | `HKLM\Software\Policies\Microsoft\VSCode` (ADMX / Intune) | policies from 1.69 |
| macOS | `.mobileconfig`, `PayloadType` `com.microsoft.VSCode`, read from `/Library/Managed Preferences/` by the bundled `@vscode/policy-watcher` | sample profile ships from 1.99 |
| Linux | `/etc/vscode/policy.json` | **1.106** |

So platform coverage is not the problem. Three other things are.

## 1. The policy URL must return a gallery *manifest*, not an API root

`getExtensionGalleryManifestFromServiceUrl()` issues a plain `GET` against the policy value
and parses the body as an `IExtensionGalleryManifest`:

```
{ version, resources: [ { id, type } ], capabilities: { … } }
```

The firewall endpoint is a VS Marketplace **API root** — the `_apis/public/gallery`
analogue. Pointing the policy at it does not work, because VS Code is asking for a service
description document, not a marketplace.

## 2. VS Code gates the policy behind a GitHub entitlement

This is the decisive one. `doGetExtensionGalleryManifest()` → `handleDefaultAccountAccess()`:

- no signed-in default (GitHub/Copilot) account → status `requiresSignIn`
- otherwise `checkAccess()` requires `account.entitlementsData.access_type_sku` to appear in
  `product.json`'s `extensionsGallery.accessSKUs` — the `copilot_enterprise_*` and
  `copilot_for_business_*` seat SKUs — **or** `account.enterprise === true`
- failing either yields a `null` manifest, which disables the Extensions view entirely

That last point matters: a failed gate is *worse* than not deploying the policy at all. A
developer without a Copilot Business/Enterprise seat loses the ability to search or install
any extension, and the failure mode is a sign-in prompt rather than anything that points at
the policy. The gate has been present since `release/1.99`, i.e. for the policy's entire
life — it is the GitHub Enterprise "private marketplace" hook, not a neutral redirect.

Field reports consistent with the gate failing closed and VS Code silently continuing to use
`product.json`:

- [microsoft/vscode#246420](https://github.com/microsoft/vscode/issues/246420) — Windows GPO ignored
- [Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5740686/macbook-vscode-use-mobleconfig-file-to-update-exte) — macOS Jamf `.mobileconfig` ignored

## 3. The policy does not reach the CLI

`ExtensionGalleryServiceUrl` appears only in `workbench.desktop.main.js`.
`out/vs/code/node/cliProcessMain.js` — which serves `code --install-extension` and
`code --list-extensions` — builds its gallery manifest purely from
`productService.extensionsGallery.serviceUrl`. So even where the policy works, the CLI is an
unmitigated bypass.

Patching `product.json` covers the CLI for free, because that is the value the CLI reads.

## Also ruled out

| Mechanism | Why not |
|---|---|
| `product.overrides.json` | Merged only when `VSCODE_DEV` is set — dev builds only |
| An env var or CLI flag | None exists; there is no `EXTENSIONS_GALLERY` or `--extensions-gallery-service-url` |
| `extensions.gallery.serviceUrl` in user `settings.json` | Same gated code path, and user-writable. The setting is `included: false`, so the policy is otherwise the only way to set it |

## What would unblock the policy path

A factory endpoint that serves an `IExtensionGalleryManifest`. That would make the policy a
viable **additional** delivery option — attractive because it is tamper-resistant and needs
no app-bundle write, hence no App Management TCC grant and no `codesign` complaints.

It would not be a replacement. The entitlement gate would still restrict it to fleets where
every developer holds a Copilot Business/Enterprise seat or a GitHub Enterprise account, and
it would still miss `code --install-extension`. The `product.json` patch would remain the
mechanism with full coverage.

## What admins can use today, alongside this

`AllowedExtensions` (setting `extensions.allowed`, `minimumVersion: 1.96`) is a genuinely
useful policy and a good complement:

- no entitlement gate
- works on Windows, macOS and Linux
- **is** enforced by the CLI as well as the workbench (`cliProcessMain.js` builds a real
  `NativePolicyService` / `FilePolicyService` and registers `IAllowedExtensionsService`)

It takes an object keyed by `*`, `publisher`, or `publisher.name`, with values
`true | false | "stable" | ["1.2.3", …]`.

This repo does **not** generate one. Endor's filtering criteria change over time, so a
snapshot baked into every client would drift immediately; the gallery URL is where
per-request evaluation belongs. `AllowedExtensions` is static admin intent, so it stays under
admin control — see
[Microsoft's documentation](https://code.visualstudio.com/docs/enterprise/policies) for how
to deploy it. The two compose cleanly: neither replaces the other.

## Verifying policy state on a machine

Useful when working out whether a policy is live at all, independently of Endor:

- Command Palette → **`Developer: Policy Diagnostics`** — shows each policy's definition,
  resolved value and source
- **`Developer: Set Log Level… → Trace`**, then Output → **Window**, filtered on
  `[Marketplace]`. Expected lines include
  `[Marketplace] Enterprise marketplace configured but user not signed in`,
  `[Marketplace] User signed in but lacks access to enterprise marketplace`, and
  `[Marketplace] Checking Account SKU access for configured gallery <sku>`
- macOS: `sudo /usr/libexec/PlistBuddy -c Print "/Library/Managed Preferences/com.microsoft.VSCode.plist"`
- Windows: `reg query "HKLM\Software\Policies\Microsoft\VSCode"`
- Linux: `cat /etc/vscode/policy.json`
