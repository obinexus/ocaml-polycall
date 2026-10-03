'use strict';

// npm package integrity: the entry point loads, its directory index is
// consistent with package.json, every file it names exists in the (packed or
// checked-out) package, and versions/URLs agree across the manifests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const binding = require('..');
const metadata = require('../package.json');
const manifest = require('../polycall-binding.json');

const escaped = metadata.version.split('.').join('[.]');

assert.equal(metadata.name, '@obinexusltd/ocaml-polycall');
assert.equal(binding.packageName, metadata.name);
assert.equal(metadata.license, 'MIT');
assert.equal(metadata.publishConfig.access, 'public');
assert.equal(metadata.repository.url, 'git+https://github.com/obinexus/ocaml-polycall.git');
assert.equal(manifest.version, metadata.version, 'polycall-binding.json version matches package.json');
assert.equal(manifest.core, 'polycall >= 1.1.0 (binding ABI 1)');
assert.equal(manifest.core_repository, 'https://github.com/obinexus/polycall');
assert.equal(manifest.repository, 'https://github.com/obinexus/ocaml-polycall');

const author = typeof metadata.author === 'string'
  ? metadata.author
  : `${metadata.author?.name} <${metadata.author?.email}>`;
assert.equal(author, 'Nnamdi Michael Okpala <okpalan@protonmail.com>');

const duneProject = fs.readFileSync(binding.duneProject, 'utf8');
assert.match(duneProject, new RegExp(`[(]version ${escaped}[)]`), 'dune-project (version) matches package.json');
assert.match(duneProject, /github obinexus[/]ocaml-polycall/);
const opam = fs.readFileSync(binding.opamFile, 'utf8');
assert.match(opam, new RegExp(`^version: "${escaped}"`, 'm'), 'ocaml-polycall.opam version matches package.json');

const metadataKeys = {
  src: 'src', include: 'include', dist: 'dist', examples: 'example', test: 'test', scripts: 'scripts'
};
for (const [name, directory] of Object.entries(binding.directories)) {
  assert.equal(fs.statSync(directory.root).isDirectory(), true, `${name} is a directory`);
  assert.ok(directory.files.length > 0, `${name} directory index is empty`);
  assert.ok(directory.files.every((file) => file.startsWith(`${directory.root}${path.sep}`)));
  const key = metadataKeys[name];
  if (key) assert.equal(metadata.directories[key], directory.relative);
}

assert.ok(binding.directories.src.relativeFiles.includes('polycall.ml'));
assert.ok(binding.directories.src.relativeFiles.includes('polycall.mli'));
assert.ok(binding.directories.src.relativeFiles.includes('ocaml_polycall_stubs.c'));
assert.ok(binding.directories.src.relativeFiles.includes('config/discover.ml'));
assert.ok(binding.directories.include.relativeFiles.includes('ocaml_polycall.h'));
assert.ok(binding.directories.examples.relativeFiles.includes('basic.ml'));
assert.ok(binding.directories.test.relativeFiles.includes('test_polycall.ml'));
assert.throws(() => binding.resolve('src', '..', 'package.json'), RangeError);
assert.equal(fs.existsSync(path.join(binding.projectRoot, 'generated')), false,
  'the stub header directory generated/ must not come back');

for (const [name, file] of Object.entries(binding)) {
  if (typeof file !== 'string' || !path.isAbsolute(file)) continue;
  assert.equal(fs.existsSync(file), true, `missing ${name}: ${file}`);
}

console.log('ocaml-polycall npm package test: PASS');
