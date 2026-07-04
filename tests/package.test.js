'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const binding = require('..');
const metadata = require('../package.json');

assert.equal(metadata.name, '@obinexusltd/ocaml-polycall');
assert.equal(metadata.license, 'MIT');
assert.equal(metadata.publishConfig.access, 'public');

const author = typeof metadata.author === 'string'
  ? metadata.author
  : `${metadata.author?.name} <${metadata.author?.email}>`;
assert.equal(author, 'Nnamdi Michael Okpala <okpalan@protonmail.com>');

const metadataKeys = {
  src: 'src',
  include: 'include',
  generated: 'generated',
  dist: 'dist',
  examples: 'example',
  tests: 'test',
  scripts: 'scripts'
};

for (const [name, directory] of Object.entries(binding.directories)) {
  const metadataKey = metadataKeys[name];
  assert.equal(metadata.directories[metadataKey], directory.relative);
  assert.equal(path.isAbsolute(metadata.directories[metadataKey]), false);
  assert.equal(fs.statSync(directory.root).isDirectory(), true);
  assert.ok(directory.files.length > 0, `${name} directory index is empty`);
  assert.ok(directory.files.every((file) => file.startsWith(`${directory.root}${path.sep}`)));
}

assert.ok(binding.directories.src.relativeFiles.includes('polycall.ml'));
assert.ok(binding.directories.src.relativeFiles.includes('polycall.mli'));
assert.ok(binding.directories.src.relativeFiles.includes('ocaml_polycall_stubs.c'));
assert.ok(binding.directories.include.relativeFiles.includes('ocaml_polycall.h'));
assert.ok(binding.directories.generated.relativeFiles.includes('polycall/polycall_ffi.h'));
assert.ok(binding.directories.examples.relativeFiles.includes('basic.ml'));
assert.throws(() => binding.resolve('src', '..', 'package.json'), RangeError);

for (const file of [
  binding.ocamlModule,
  binding.ocamlInterface,
  binding.runtimeStub,
  binding.nativeSource,
  binding.nativeHeader,
  binding.ffiHeader,
  binding.config,
  binding.manifest,
  binding.duneProject,
  binding.makefile
]) {
  assert.equal(path.isAbsolute(file), true, `path is not absolute: ${file}`);
  assert.equal(fs.existsSync(file), true, `missing project file: ${file}`);
}

console.log('ocaml-polycall npm relative-directory index test: PASS');
