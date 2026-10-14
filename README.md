# Z-JSON

[![Zig Version](https://img.shields.io/badge/zig-0.17.0-orange.svg)](https://ziglang.org/)
[![API docs](https://img.shields.io/badge/API-Zig_docs-blue.svg)](https://carlos-sweb.github.io/z-json/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

ECMAScript-compatible **`JSON.stringify()`/`JSON.parse()`** over [z-value](https://github.com/carlos-sweb/z-value)'s `JSValue`, in Zig 0.17.0, part of the [z-*](https://github.com/carlos-sweb) micro-library ecosystem.

## Why this depends on z-value directly

Unlike `z-error`/`z-math` (which are generic or operate on plain `f64`), `JSON.stringify`/`JSON.parse` walk the *entire heterogeneous value tree* — arrays of objects of strings of numbers, arbitrarily nested. That can only be expressed over the unified `JSValue` type, not over any single monomorphic container.

## Scope

No `replacer`/`space` arguments (pretty-printing, property filtering) — those are a straightforward layer on top of `stringify()`'s core algorithm and can be added without changing what's here. No `toJSON()` hooks are invoked during serialization.

## Design

- **`stringify(allocator, value) ![]u8`** — no replacer/space. Follows ECMA-262's `SerializeJSONProperty` exactly for the cases that matter in practice:
  - `undefined`/`symbol` **at the top level** produce `JSONError.Unserializable` (real JS returns the *value* `undefined`, which isn't a `[]u8` — this is the one place the API can't mirror the spec exactly).
  - `undefined`/`symbol` as an **array element** serialize as `"null"`; as an **object property**, the property is **omitted** entirely. Both match spec.
  - `NaN`/`±Infinity` serialize as `"null"` (a real string, not an error — they *are* serializable, just not representable as a JSON number).
  - `regex`/`map`/`set`/`error` values serialize as `"{}"` — this isn't a shortcut, it's what real `JSON.stringify(new Map())`/`JSON.stringify(new TypeError())` actually produce, since none of those types have their own enumerable properties by default.
  - Numbers go through [z-number](https://github.com/carlos-sweb/z-number)'s spec-exact `Number::toString`, the same formatter z-array/z-value already use elsewhere.
  - Strings escape `"`, `\`, and control characters (`\b \f \n \r \t`, `\u00XX` for the rest); everything else — including multi-byte UTF-8 — passes through verbatim, which is valid JSON. Lone UTF-16 surrogates stored as WTF-8 are emitted as `\uXXXX` escapes.
- **`parse(allocator, text) JSONError!JSValue`** — recursive descent over the strict JSON grammar, which is *not* the same as JS's own number-literal grammar: no leading `+`, no hex/octal/binary, no leading zeros except a bare `"0"`, and an exponent requires at least one digit. `\uXXXX` escapes are decoded, including surrogate pairs (combined into one codepoint); a lone/unpaired surrogate escape is preserved as WTF-8 and re-escaped by `stringify`. The returned tree is a normal `JSValue` tree — free it with one top-level `.deinit()`, same as any hand-built tree.
- **`JSONError`**: `UnexpectedToken`, `UnexpectedEnd`, `InvalidNumber`, `InvalidString`, `TrailingData`, `Unserializable`, `CircularStructure`, `OutOfMemory`.

## Usage

```zig
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

var obj = try JSValue.newObject(allocator);
defer obj.deinit();
try obj.object.value.set("name", try JSValue.newString(allocator, "z-json"));
try obj.object.value.set("version", JSValue.fromNumber(1.0));

const text = try zjson.stringify(allocator, obj);
defer allocator.free(text);
// text == "{\"name\":\"z-json\",\"version\":1}"

var parsed = try zjson.parse(allocator, text);
defer parsed.deinit();
```

## Dependencies and validation

Requires Zig 0.17.0 or newer. Dependencies are downloaded from the
`carlos-sweb` GitHub releases, with URLs and package hashes pinned in
`build.zig.zon`. No sibling checkouts are required.

```sh
zig build test --summary all
```

## License

MIT

## API documentation

[Browse the generated Zig API documentation](https://carlos-sweb.github.io/z-json/).

Generate the same documentation locally with Zig 0.17.0:

```sh
zig build docs
python3 -m http.server 8000 --directory zig-out/docs
```

Open `http://localhost:8000/` to browse it. GitHub Actions runs the tests,
generates the native Zig docs, and publishes `zig-out/docs` to GitHub Pages
automatically on every push to `master`. Pull requests also validate tests
and documentation generation.
