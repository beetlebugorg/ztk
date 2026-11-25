# npm package

The npm package `@beetlebug/ztk` has `ztk.wasm`, the ES module `web/ztk.js`, and the TypeScript types. The name of the package is in `npm/package.json`. The README of the package is [`npm/README.md`](../npm/README.md).

## Use the package

```sh
npm install @beetlebug/ztk
```

```js
import * as ztk from "@beetlebug/ztk";

const app = await ztk.mount(document.getElementById("app"), {
  script: "button .b -text Hello; pack .b -padx 8 -pady 8",
});
```

The same import works in a bundler and from a CDN with no build step. [ztk on the web](web.md) has the API.

## The files

| File | Use |
|---|---|
| `npm/package.json` | The name, the entries, and the file list. The version in it is a placeholder. |
| `npm/README.md` | The README on npmjs.com. `{{name}}` and `{{version}}` change to the name and the version. |
| `npm/ztk.d.ts` | The types. |
| `npm/NOTICE` | The third-party notices of `ztk.wasm`. The package also has `LICENSE` and `licenses/`, with the license files of ztcl and of the Inter font. |
| `npm/build.mjs` | Puts the files of the package in `zig-out/npm`. |
| `npm/test/run.mjs` | Packs the package and tests the tarball. |
| `.github/workflows/npm.yml` | Tests the package on each pull request, and publishes it on a version tag. |

## Build and test

```sh
zig build wasm
node npm/build.mjs
node npm/test/run.mjs
```

`run.mjs` runs `npm pack` and installs the tarball in new projects in the temp folder:

- `node`: runs `npm/test/test.mjs` in Node.js and checks `npm/test/types.ts` with `tsc --strict`. Node.js has no DOM, so `test.mjs` runs `ztk.wasm` through its exports with the CPU renderer.
- `browser`: builds `npm/test/page` with Vite and runs it in headless Chromium at a device pixel ratio of 2. It also runs the page on the Vite dev server. The page mounts apps with WebGL 2 and with the CPU renderer, clicks a button through the DOM, and checks `size: "fill"`, HiDPI, and `destroy`. `npm/test/page/expected.json` has the expected result.
- `cdn`: serves the package from a second origin in the folder layout of jsDelivr, and a plain HTML page imports it with no build step.

Give one or more of `node`, `browser`, and `cdn` to run only those tests. The browser tests need Chromium. Set `CHROME` to the browser program and `PLAYWRIGHT_CORE` to a folder of `playwright-core`. With no `PLAYWRIGHT_CORE`, the test installs `playwright-core` from npm.

## Versions

The version of the package is the tag with no `v`. The tag `v0.2.0` gives `0.2.0`, and `v0.2.0-beta` gives `0.2.0-beta`. `npm/build.mjs --version` sets the version. With no `--version`, it uses the tag on `HEAD`, or else `0.0.0`.

Each version goes to the `latest` dist-tag, also an `-alpha` or `-beta` version. npm needs a dist-tag for a prerelease version. When ztk has a release with no suffix, change the workflow to give `-alpha` and `-beta` versions the dist-tag `next`.

## Publish

`.github/workflows/npm.yml` runs on each push of a version tag. It builds `ztk.wasm`, runs the package tests, and runs `npm publish`. The publish uses npm trusted publishing. GitHub Actions gives npm a short OIDC token, and npm adds a provenance statement to the version. The repository has no long-lived npm token.

### Staged publishing

The workflow stages each release with `npm stage publish`. A staged version is not public. The maintainer approves it with 2FA on npmjs.com (the package page lists the staged versions), or with `npm stage list` and `npm stage approve <stage-id>`. The trusted publisher allows only `npm stage publish`, not `npm publish` or `npm dist-tag`, as npm recommends. So no workflow can make a version public without a person.

### One-time steps

1. Sign in to npmjs.com. Create the organization `beetlebug` (Add Organization, the free plan for public packages).
2. Add the trusted publisher. On npmjs.com, open the settings of the package `@beetlebug/ztk`, and go to Trusted Publisher. Select GitHub Actions and enter these values:
   - Organization or user: `beetlebugorg`
   - Repository: `ztk`
   - Workflow filename: `npm.yml`
   - Environment name: `npm`
3. Push a version tag, for example `git tag v0.2.0-beta && git push origin v0.2.0-beta`. The `npm` workflow publishes the version.

A new trusted publisher must publish within 2 days, or the configuration expires.

### The first publish

The npm docs set up a trusted publisher in the settings of a package. These docs do not say if a package that is not on npm yet has settings. If npmjs.com shows no settings for `@beetlebug/ztk`, do the first publish with a token:

1. On npmjs.com, make a granular access token with read and write access to the `beetlebug` organization. Give it a short expiry.
2. In the repository settings on GitHub, add the secret `NPM_TOKEN` with the token. Add it in the environment `npm`, or as a repository secret.
3. Push the tag. The workflow publishes with the token, with provenance.
4. Add the trusted publisher (step 2 above).
5. Delete the `NPM_TOKEN` secret, and revoke the token on npmjs.com.
6. In the package settings, under Publishing access, select "Require two-factor authentication and disallow tokens". Trusted publishing continues to work with this setting.

With no `NPM_TOKEN` secret, the workflow uses only trusted publishing.

### Requirements

Trusted publishing needs npm 11.5.1 or later and Node.js 22.14.0 or later. The workflow uses Node.js 24 and installs npm 11. Provenance needs a public repository and a public package.

## Pull requests

On each pull request and each push to `main`, the `Package` job of the `npm` workflow builds the package, runs the tests, and runs `npm publish --dry-run`. The `Publish` job runs only on a tag.
