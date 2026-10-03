'use strict';

// ocaml-polycall is a source distribution of an OCaml/dune
// binding of the Polycall binding ABI v1; requiring it from Node.js only
// indexes the packaged files (build them with dune, see README.md).
const fs = require('node:fs');
const path = require('node:path');

const relativeDirectories = Object.freeze({
  src: 'src',
  include: 'include',
  dist: 'dist',
  examples: 'examples',
  test: 'test',
  tests: 'tests',
  scripts: 'scripts'
});

function walkFiles(root, current = root) {
  return fs.readdirSync(current, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name))
    .flatMap((entry) => {
      const absolutePath = path.join(current, entry.name);
      return entry.isDirectory() ? walkFiles(root, absolutePath) : [absolutePath];
    });
}

function indexDirectory(relativePath) {
  const root = path.join(__dirname, relativePath);
  const files = walkFiles(root);
  return Object.freeze({
    relative: relativePath,
    root,
    files: Object.freeze(files),
    relativeFiles: Object.freeze(
      files.map((file) => path.relative(root, file).split(path.sep).join('/'))
    )
  });
}

const directories = Object.freeze(
  Object.fromEntries(
    Object.entries(relativeDirectories).map(([name, relativePath]) => [
      name,
      indexDirectory(relativePath)
    ])
  )
);

function resolve(directoryName, ...segments) {
  const directory = directories[directoryName];
  if (!directory) {
    throw new RangeError(`unknown ocaml-polycall directory: ${directoryName}`);
  }

  const resolved = path.resolve(directory.root, ...segments);
  const prefix = `${directory.root}${path.sep}`;
  if (resolved !== directory.root && !resolved.startsWith(prefix)) {
    throw new RangeError(`path escapes ocaml-polycall ${directoryName} directory`);
  }
  return resolved;
}

module.exports = Object.freeze({
  packageName: 'ocaml-polycall',
  language: 'OCaml',
  abi: 1,
  projectRoot: __dirname,
  directories,
  resolve,
  ocamlModule: path.join(__dirname, 'src', 'polycall.ml'),
  ocamlInterface: path.join(__dirname, 'src', 'polycall.mli'),
  runtimeStub: path.join(__dirname, 'src', 'ocaml_polycall_stubs.c'),
  nativeSource: path.join(__dirname, 'src', 'ocaml_polycall.c'),
  nativeHeader: path.join(__dirname, 'include', 'ocaml_polycall.h'),
  discover: path.join(__dirname, 'src', 'config', 'discover.ml'),
  testSuite: path.join(__dirname, 'test', 'test_polycall.ml'),
  config: path.join(__dirname, 'ocaml-polycallrc'),
  manifest: path.join(__dirname, 'polycall-binding.json'),
  duneProject: path.join(__dirname, 'dune-project'),
  opamFile: path.join(__dirname, 'ocaml-polycall.opam'),
  makefile: path.join(__dirname, 'Makefile')
});
