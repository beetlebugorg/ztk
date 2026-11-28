#!/usr/bin/env node
// Puts the files of the npm package in zig-out/npm. Run `zig build wasm`
// first. The name of the package is in npm/package.json only.
//
//   node npm/build.mjs [--version 0.2.0] [--out dir]
//
// The version is the --version value, or the tag on HEAD with no "v",
// or the version in npm/package.json.
// SPDX-License-Identifier: BSD-2-Clause
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const arg = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const out = path.resolve(arg("--out") ?? path.join(root, "zig-out/npm"));
const pkg = JSON.parse(fs.readFileSync(path.join(root, "npm/package.json"), "utf8"));

function tagVersion() {
  try {
    const tag = execFileSync("git", ["describe", "--tags", "--exact-match", "HEAD"], { cwd: root, stdio: ["ignore", "pipe", "ignore"] });
    return String(tag).trim().replace(/^v/, "");
  } catch {
    return undefined;
  }
}

const version = (arg("--version") ?? tagVersion() ?? pkg.version).replace(/^v/, "");
if (!/^\d+\.\d+\.\d+(-(alpha|beta|rc)(\.\d+)?)?$/.test(version)) {
  console.error(`error: the version "${version}" is not X.Y.Z, X.Y.Z-alpha[.N], X.Y.Z-beta[.N], or X.Y.Z-rc.N`);
  process.exit(1);
}
pkg.version = version;

// [file in the package, file in the repository]
const copies = [
  ["ztk.js", "web/ztk.js"],
  ["webgpu.js", "web/webgpu.js"],
  ["ztk.wasm", "zig-out/web/ztk.wasm"],
  ["ztk.d.ts", "npm/ztk.d.ts"],
  ["NOTICE", "npm/NOTICE"],
  ["LICENSE", "LICENSE"],
  ["licenses/LICENSE-Inter.txt", "assets/fonts/LICENSE-Inter.txt"],
];

// ztk.wasm has ztcl in it. Its license files come from the ztcl package
// that `zig build` puts in zig-pkg.
const pkgDir = path.join(root, "zig-pkg");
const ztcl = fs.existsSync(pkgDir) ? fs.readdirSync(pkgDir).find((d) => d.startsWith("ztcl-")) : undefined;
if (!ztcl || !fs.existsSync(path.join(pkgDir, ztcl, "LICENSE"))) {
  console.error("error: the ztcl package has no LICENSE in zig-pkg. Run zig build wasm.");
  process.exit(1);
}
copies.push(["licenses/ztcl/LICENSE", `zig-pkg/${ztcl}/LICENSE`]);
for (const f of fs.readdirSync(path.join(pkgDir, ztcl, "licenses"))) copies.push([`licenses/ztcl/${f}`, `zig-pkg/${ztcl}/licenses/${f}`]);

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, "licenses/ztcl"), { recursive: true });
for (const [to, from] of copies) {
  const src = path.join(root, from);
  if (!fs.existsSync(src)) {
    console.error(`error: ${from} is missing${from.endsWith(".wasm") ? ". Run zig build wasm." : ""}`);
    process.exit(1);
  }
  fs.copyFileSync(src, path.join(out, to));
}
const readme = fs.readFileSync(path.join(root, "npm/README.md"), "utf8");
fs.writeFileSync(path.join(out, "README.md"), readme.replaceAll("{{name}}", pkg.name).replaceAll("{{version}}", version));
fs.writeFileSync(path.join(out, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
console.log(`${pkg.name}@${version} in ${path.relative(process.cwd(), out) || "."}`);
