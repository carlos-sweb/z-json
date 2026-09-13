const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const zbuffer = @import("zbuffer");
const JSValue = zvalue.JSValue;

pub const JSONError = error{
    UnexpectedToken,
    UnexpectedEnd,
    InvalidNumber,
    InvalidString,
    TrailingData,
    /// JSON.stringify(undefined) / JSON.stringify(Symbol()) return the JS
    /// value `undefined`, not a string -- there's no []u8 that represents
    /// that, so the top-level call surfaces this instead. Nested occurrences
    /// (array elements, object properties) are handled per-spec without
    /// erroring: an undefined/symbol array element serializes as "null",
    /// and an undefined/symbol object property is omitted entirely.
    Unserializable,
    /// A cycle in the value graph (an array/object reachable from
    /// itself) -- real JSON.stringify throws `TypeError: Converting
    /// circular structure to JSON`; the embedder maps this to that.
    CircularStructure,
    OutOfMemory,
};

fn isUnserializable(v: JSValue) bool {
    return switch (v) {
        // Real JSON.stringify treats function values the same way as
        // undefined: omitted from objects, `null` in arrays, and
        // JSONError.Unserializable at the top level -- not serialized as
        // an empty object.
        // NARROWING: real Temporal instances have no own enumerable
        // properties, so real JSON.stringify actually serializes them as
        // `{}` (no toJSON, SerializeJSONObject finds nothing to write) --
        // NOT unserializable. Treated the same as function/symbol here
        // anyway (simpler, and `{}` would be equally useless/misleading
        // output) -- revisit if a real consumer needs the spec-exact `{}`.
        .@"undefined", .symbol, .function, .temporal => true,
        else => false,
    };
}

/// If `bytes` starts with this engine's WTF-8 encoding of a lone
/// UTF-16 surrogate (z-string's `encodeSurrogateWtf8` -- duplicated
/// here since this package has no dependency on z-string, matching
/// the rest of this ~30-repo family's "small standalone libraries"
/// convention), returns its value. See z-string-surrogate-charat.md.
fn encodeWtf8Surrogate(buf: *[3]u8, surrogate: u16) void {
    buf[0] = 0xE0 | @as(u8, @intCast(surrogate >> 12));
    buf[1] = 0x80 | @as(u8, @intCast((surrogate >> 6) & 0x3F));
    buf[2] = 0x80 | @as(u8, @intCast(surrogate & 0x3F));
}

fn decodeWtf8Surrogate(bytes: []const u8) ?u16 {
    if (bytes.len < 3) return null;
    if (bytes[0] & 0xF0 != 0xE0) return null;
    if (bytes[1] & 0xC0 != 0x80 or bytes[2] & 0xC0 != 0x80) return null;
    const value: u21 = (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
    if (value < 0xD800 or value > 0xDFFF) return null;
    return @intCast(value);
}

fn writeQuotedString(allocator: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => {
                try buf.appendSlice(allocator, "\\\"");
                i += 1;
            },
            '\\' => {
                try buf.appendSlice(allocator, "\\\\");
                i += 1;
            },
            0x08 => {
                try buf.appendSlice(allocator, "\\b");
                i += 1;
            },
            0x0C => {
                try buf.appendSlice(allocator, "\\f");
                i += 1;
            },
            '\n' => {
                try buf.appendSlice(allocator, "\\n");
                i += 1;
            },
            '\r' => {
                try buf.appendSlice(allocator, "\\r");
                i += 1;
            },
            '\t' => {
                try buf.appendSlice(allocator, "\\t");
                i += 1;
            },
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var esc_buf: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, esc);
                i += 1;
            },
            else => {
                // A lone WTF-8-encoded surrogate (from splitting an
                // astral pair, or an unpaired `\u` escape) must come
                // out as a real `\uXXXX` ASCII escape -- its raw
                // bytes aren't valid UTF-8, and JSON text must be
                // well-formed UTF-8 (confirmed against real Node:
                // `JSON.stringify("\ud800")` is the 8-character text
                // `"\ud800"`, not 3 raw bytes).
                if (decodeWtf8Surrogate(s[i..])) |surrogate| {
                    var esc_buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{surrogate}) catch unreachable;
                    try buf.appendSlice(allocator, esc);
                    i += 3;
                    continue;
                }
                // Every other byte (ASCII printable, or a UTF-8
                // continuation/lead byte >= 0x80) is valid to emit
                // verbatim inside a JSON string; walking byte-by-byte
                // still reconstructs multi-byte UTF-8 sequences
                // correctly since none of their bytes collide with
                // the escaped ranges above or with a WTF-8 surrogate's
                // own leading-byte shape (0xE0-0xEF, checked first).
                try buf.append(allocator, c);
                i += 1;
            },
        }
    }
    try buf.append(allocator, '"');
}

/// The container pointers on the current serialization PATH (not all
/// visited -- diamonds are legal, cycles are not), for cycle detection.
const SeenStack = std.ArrayList(usize);

fn seenContains(seen: *const SeenStack, ptr: usize) bool {
    for (seen.items) |p| {
        if (p == ptr) return true;
    }
    return false;
}

/// Shared by the plain `.number` arm and typed-array element serialization
/// below -- both need the exact same NaN/Inf->"null" + znumber formatting.
fn writeNumberLiteral(allocator: Allocator, buf: *std.ArrayList(u8), n: f64) JSONError!void {
    if (std.math.isNan(n) or std.math.isInf(n)) {
        try buf.appendSlice(allocator, "null");
    } else {
        // radix is always `null` (base 10) here, so RangeError/bignum
        // internal errors are unreachable in practice; still must be
        // mapped since Zig requires the full inferred error set handled.
        const s = znumber.FormattingMethods.toString(n, allocator, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
}

/// Real JSON.stringify serializes a TypedArray's indexed elements as a
/// plain object (`{"0":1,"1":2,...}`), not `{}` -- verified against real
/// Node. BigInt64Array/BigUint64Array elements are real BigInts, which
/// JSON.stringify always throws on (matches the `.bigint` arm below).
fn writeTypedArrayElem(allocator: Allocator, buf: *std.ArrayList(u8), box: *zvalue.TypedArrayBox) JSONError!void {
    if (box.kind == .i64 or box.kind == .u64) return JSONError.Unserializable;
    const arraybuf = &box.owner.array_buffer.value;
    try buf.append(allocator, '{');

    // Build the view ONCE per kind (not per element) -- these `catch
    // unreachable` calls are safe because `box.byte_offset`/`box.len` were
    // already validated when the TypedArray was constructed.
    switch (box.kind) {
        inline .i8, .u8, .u8_clamped, .i16, .u16, .i32, .u32, .f32, .f64 => |kind| {
            const T = comptime switch (kind) {
                .i8 => i8,
                .u8, .u8_clamped => u8,
                .i16 => i16,
                .u16 => u16,
                .i32 => i32,
                .u32 => u32,
                .f32 => f32,
                .f64 => f64,
                else => unreachable,
            };
            const view = zbuffer.TypedArrayView(T).init(arraybuf, box.byte_offset, box.len) catch unreachable;
            var i: usize = 0;
            while (i < box.len) : (i += 1) {
                if (i != 0) try buf.append(allocator, ',');
                const idx = std.fmt.allocPrint(allocator, "\"{d}\":", .{i}) catch return error.OutOfMemory;
                defer allocator.free(idx);
                try buf.appendSlice(allocator, idx);
                const v = view.get(i) catch unreachable;
                const n: f64 = if (T == f32 or T == f64) v else @floatFromInt(v);
                try writeNumberLiteral(allocator, buf, n);
            }
        },
        .i64, .u64 => unreachable, // returned Unserializable above
    }
    try buf.append(allocator, '}');
}

fn writeValue(allocator: Allocator, buf: *std.ArrayList(u8), seen: *SeenStack, value: JSValue) JSONError!void {
    switch (value) {
        // isUnserializable() already filters .function out of every
        // recursive call site before writeValue() would see one; this arm
        // exists only so the switch stays exhaustive.
        // Real Temporal types have no default toJSON either -- same
        // "unserializable, becomes null" bucket as function/symbol.
        .@"undefined", .symbol, .function, .temporal => try buf.appendSlice(allocator, "null"),
        .@"null" => try buf.appendSlice(allocator, "null"),
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .number => |n| try writeNumberLiteral(allocator, buf, n),
        .string => |box| try writeQuotedString(allocator, buf, box.value.data),
        // Real JSON.stringify serializes a Date as its quoted ISO string
        // (via Date.prototype.toJSON).
        .date => |box| {
            const iso = box.value.toISOString(allocator) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // Invalid Date stringifies as null in real JS.
                else => return buf.appendSlice(allocator, "null"),
            };
            defer allocator.free(iso);
            try writeQuotedString(allocator, buf, iso);
        },
        .array => |box| {
            if (seenContains(seen, @intFromPtr(box))) return JSONError.CircularStructure;
            try seen.append(allocator, @intFromPtr(box));
            defer _ = seen.pop();
            try buf.append(allocator, '[');
            for (box.value.toSlice(), 0..) |item, i| {
                if (i != 0) try buf.append(allocator, ',');
                if (isUnserializable(item)) {
                    try buf.appendSlice(allocator, "null");
                } else {
                    try writeValue(allocator, buf, seen, item);
                }
            }
            try buf.append(allocator, ']');
        },
        .object => |box| {
            if (seenContains(seen, @intFromPtr(box))) return JSONError.CircularStructure;
            try seen.append(allocator, @intFromPtr(box));
            defer _ = seen.pop();
            try buf.append(allocator, '{');
            const keys = try box.value.keys(allocator);
            defer allocator.free(keys);
            var first = true;
            for (keys) |key| {
                // Reserved internal keys (embedder symbol-key encoding,
                // `\x00`-prefixed) are never serialized -- symbols aren't
                // JSON keys.
                if (key.len > 0 and key[0] == 0) continue;
                const v = box.value.get(key).?;
                if (isUnserializable(v)) continue;
                if (!first) try buf.append(allocator, ',');
                first = false;
                try writeQuotedString(allocator, buf, key);
                try buf.append(allocator, ':');
                try writeValue(allocator, buf, seen, v);
            }
            try buf.append(allocator, '}');
        },
        // Matches real JS: RegExp/Map/Set/Error/Promise instances have no
        // own enumerable properties by default, so JSON.stringify(x) for
        // any of them is "{}" unless a custom toJSON()/property exists
        // (functions aren't modeled yet, so that escape hatch doesn't
        // apply here).
        // Proxy joins this bucket too (documented narrowing, not fixed
        // for now): real JSON.stringify(proxy) would invoke traps
        // through to the target, which needs an interpreter/trap-calling
        // hook z-json doesn't have (a standalone package, no callback
        // into JS) -- a real architectural gap, not a simple switch arm.
        // ArrayBuffer/DataView also give "{}" here, which matches real
        // Node exactly (they have no enumerable own properties either).
        .regex, .map, .set, .@"error", .promise, .proxy, .array_buffer, .data_view => try buf.appendSlice(allocator, "{}"),
        // Unlike ArrayBuffer/DataView above, a TypedArray's indexed
        // elements ARE real enumerable own properties in JS -- real Node
        // serializes them (`JSON.stringify(new Uint8Array([1,2,3]))` ->
        // `{"0":1,"1":2,"2":3}`). BigInt64Array/BigUint64Array elements
        // throw the same Unserializable error a bare BigInt does.
        .typed_array => |box| try writeTypedArrayElem(allocator, buf, &box.value),
        // Unlike undefined/symbol/function (silently omitted/nulled) and
        // unlike Date (silently serialized), real JSON.stringify THROWS
        // on a BigInt at ANY position -- top-level, array element, or
        // object property ("Do not know how to serialize a BigInt").
        // Deliberately NOT added to isUnserializable()'s omit-bucket:
        // that would silently null/omit it instead of propagating this
        // error through the array/object recursion above.
        .bigint => return JSONError.Unserializable,
    }
}

/// JSON.stringify(value) with no replacer/space argument.
pub fn stringify(allocator: Allocator, value: JSValue) JSONError![]u8 {
    if (isUnserializable(value)) return JSONError.Unserializable;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var seen: SeenStack = .empty;
    defer seen.deinit(allocator);
    try writeValue(allocator, &buf, &seen, value);
    return buf.toOwnedSlice(allocator);
}

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,

    fn peekByteOrEnd(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => break,
            }
        }
    }

    fn parseUnicodeEscape(self: *Parser) JSONError!u16 {
        if (self.pos + 4 > self.input.len) return JSONError.UnexpectedEnd;
        const hex = self.input[self.pos .. self.pos + 4];
        const value = std.fmt.parseInt(u16, hex, 16) catch return JSONError.InvalidString;
        self.pos += 4;
        return value;
    }

    /// Returns an allocator-owned []u8; caller frees it.
    fn parseRawString(self: *Parser) JSONError![]u8 {
        std.debug.assert(self.input[self.pos] == '"');
        self.pos += 1;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        while (true) {
            if (self.pos >= self.input.len) return JSONError.UnexpectedEnd;
            const c = self.input[self.pos];
            if (c == '"') {
                self.pos += 1;
                break;
            }
            if (c < 0x20) return JSONError.InvalidString;
            if (c != '\\') {
                try buf.append(self.allocator, c);
                self.pos += 1;
                continue;
            }

            self.pos += 1;
            if (self.pos >= self.input.len) return JSONError.UnexpectedEnd;
            const esc = self.input[self.pos];
            switch (esc) {
                '"' => {
                    try buf.append(self.allocator, '"');
                    self.pos += 1;
                },
                '\\' => {
                    try buf.append(self.allocator, '\\');
                    self.pos += 1;
                },
                '/' => {
                    try buf.append(self.allocator, '/');
                    self.pos += 1;
                },
                'b' => {
                    try buf.append(self.allocator, 0x08);
                    self.pos += 1;
                },
                'f' => {
                    try buf.append(self.allocator, 0x0C);
                    self.pos += 1;
                },
                'n' => {
                    try buf.append(self.allocator, '\n');
                    self.pos += 1;
                },
                'r' => {
                    try buf.append(self.allocator, '\r');
                    self.pos += 1;
                },
                't' => {
                    try buf.append(self.allocator, '\t');
                    self.pos += 1;
                },
                'u' => {
                    self.pos += 1;
                    const first = try self.parseUnicodeEscape();
                    var cp: u21 = first;
                    // A lone surrogate (unpaired \u escape) is a real,
                    // legal JS string value -- WTF-8-encode it (z-string's
                    // encodeSurrogateWtf8, duplicated here since this
                    // package doesn't depend on z-string) instead of
                    // substituting U+FFFD, confirmed against real Node:
                    // `JSON.parse('"\\ud800"')` preserves the surrogate
                    // (round-trips through JSON.stringify as `"\ud800"`),
                    // it does not become the replacement character.
                    var lone_surrogate: ?u16 = null;
                    if (first >= 0xD800 and first <= 0xDBFF) {
                        // High surrogate: look for a following \uXXXX low
                        // surrogate to combine into one codepoint.
                        if (self.pos + 1 < self.input.len and self.input[self.pos] == '\\' and self.input[self.pos + 1] == 'u') {
                            const save = self.pos;
                            self.pos += 2;
                            const second = try self.parseUnicodeEscape();
                            if (second >= 0xDC00 and second <= 0xDFFF) {
                                cp = 0x10000 + (@as(u21, first - 0xD800) << 10) + (@as(u21, second - 0xDC00));
                            } else {
                                // Not a low surrogate after all -- rewind and
                                // treat the high surrogate as lone.
                                self.pos = save;
                                lone_surrogate = first;
                            }
                        } else {
                            lone_surrogate = first; // lone high surrogate
                        }
                    } else if (first >= 0xDC00 and first <= 0xDFFF) {
                        lone_surrogate = first; // lone low surrogate
                    }
                    if (lone_surrogate) |surrogate| {
                        var wtf8_buf: [3]u8 = undefined;
                        encodeWtf8Surrogate(&wtf8_buf, surrogate);
                        try buf.appendSlice(self.allocator, &wtf8_buf);
                    } else {
                        var enc_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &enc_buf) catch return JSONError.InvalidString;
                        try buf.appendSlice(self.allocator, enc_buf[0..len]);
                    }
                },
                else => return JSONError.InvalidString,
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn parseStringValue(self: *Parser) JSONError!JSValue {
        const raw = try self.parseRawString();
        defer self.allocator.free(raw);
        return try JSValue.newString(self.allocator, raw);
    }

    fn parseNumberValue(self: *Parser) JSONError!JSValue {
        const start = self.pos;
        if (self.peekByteOrEnd() == '-') self.pos += 1;

        if (self.pos >= self.input.len or self.input[self.pos] < '0' or self.input[self.pos] > '9') {
            return JSONError.InvalidNumber;
        }
        if (self.input[self.pos] == '0') {
            self.pos += 1;
            // A leading zero must not be followed by another digit ("01" is
            // invalid JSON, unlike "0.5" or "0e1" where '.'/'e' follow).
            if (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                return JSONError.InvalidNumber;
            }
        } else {
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') self.pos += 1;
        }

        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            const frac_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') self.pos += 1;
            if (self.pos == frac_start) return JSONError.InvalidNumber;
        }

        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            const exp_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') self.pos += 1;
            if (self.pos == exp_start) return JSONError.InvalidNumber;
        }

        const slice = self.input[start..self.pos];
        const value = std.fmt.parseFloat(f64, slice) catch return JSONError.InvalidNumber;
        return JSValue.fromNumber(value);
    }

    fn parseLiteral(self: *Parser, comptime keyword: []const u8, value: JSValue) JSONError!JSValue {
        if (self.pos + keyword.len > self.input.len) return JSONError.UnexpectedEnd;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + keyword.len], keyword)) return JSONError.UnexpectedToken;
        self.pos += keyword.len;
        return value;
    }

    fn parseArray(self: *Parser) JSONError!JSValue {
        self.pos += 1; // consume '['
        var arr = try JSValue.newArray(self.allocator);
        errdefer arr.deinit();

        self.skipWs();
        if (self.peekByteOrEnd() == ']') {
            self.pos += 1;
            return arr;
        }

        while (true) {
            self.skipWs();
            const value = try self.parseValue();
            errdefer value.deinit();
            _ = try arr.array.value.push(value);

            self.skipWs();
            const c = self.peekByteOrEnd() orelse return JSONError.UnexpectedEnd;
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == ']') {
                self.pos += 1;
                break;
            }
            return JSONError.UnexpectedToken;
        }

        return arr;
    }

    fn parseObject(self: *Parser) JSONError!JSValue {
        self.pos += 1; // consume '{'
        var obj = try JSValue.newObject(self.allocator);
        errdefer obj.deinit();

        self.skipWs();
        if (self.peekByteOrEnd() == '}') {
            self.pos += 1;
            return obj;
        }

        while (true) {
            self.skipWs();
            if (self.peekByteOrEnd() != '"') return JSONError.UnexpectedToken;
            const key = try self.parseRawString();
            defer self.allocator.free(key);

            self.skipWs();
            if (self.peekByteOrEnd() != ':') return JSONError.UnexpectedToken;
            self.pos += 1;
            self.skipWs();

            const value = try self.parseValue();
            errdefer value.deinit();
            // A freshly-created object (see JSValue.newObject() above) is
            // never frozen/sealed/non-extensible, so ZObjectError's variants
            // besides OutOfMemory are unreachable here; still must be mapped
            // since Zig requires the full inferred error set handled.
            obj.object.value.set(key, value) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };

            self.skipWs();
            const c = self.peekByteOrEnd() orelse return JSONError.UnexpectedEnd;
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == '}') {
                self.pos += 1;
                break;
            }
            return JSONError.UnexpectedToken;
        }

        return obj;
    }

    fn parseValue(self: *Parser) JSONError!JSValue {
        self.skipWs();
        const c = self.peekByteOrEnd() orelse return JSONError.UnexpectedEnd;
        return switch (c) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => self.parseStringValue(),
            't' => self.parseLiteral("true", JSValue.fromBool(true)),
            'f' => self.parseLiteral("false", JSValue.fromBool(false)),
            'n' => self.parseLiteral("null", JSValue.NULL),
            '-', '0'...'9' => self.parseNumberValue(),
            else => JSONError.UnexpectedToken,
        };
    }
};

/// JSON.parse(text), strict JSON grammar (a subset of JS number-literal
/// grammar: no leading '+', no hex/octal/binary, no leading zeros except a
/// bare "0", an exponent requires at least one digit). The returned JSValue
/// tree is freeable with a single top-level `.deinit()`, same as any other
/// hand-built JSValue tree.
pub fn parse(allocator: Allocator, text: []const u8) JSONError!JSValue {
    var parser = Parser{ .allocator = allocator, .input = text, .pos = 0 };
    const value = try parser.parseValue();
    errdefer value.deinit();
    parser.skipWs();
    if (parser.pos != text.len) return JSONError.TrailingData;
    return value;
}

test "stringify primitives" {
    const allocator = std.testing.allocator;

    const n = try stringify(allocator, JSValue.fromNumber(42.0));
    defer allocator.free(n);
    try std.testing.expectEqualStrings("42", n);

    const nan_s = try stringify(allocator, JSValue.fromNumber(std.math.nan(f64)));
    defer allocator.free(nan_s);
    try std.testing.expectEqualStrings("null", nan_s);

    const b = try stringify(allocator, JSValue.fromBool(true));
    defer allocator.free(b);
    try std.testing.expectEqualStrings("true", b);

    const null_s = try stringify(allocator, JSValue.NULL);
    defer allocator.free(null_s);
    try std.testing.expectEqualStrings("null", null_s);

    try std.testing.expectError(JSONError.Unserializable, stringify(allocator, JSValue.UNDEFINED));
}

test "stringify escapes control characters and quotes" {
    const allocator = std.testing.allocator;
    var s = try JSValue.newString(allocator, "a\"b\\c\n\td");
    defer s.deinit();

    const out = try stringify(allocator, s);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\td\"", out);
}

test "stringify array: undefined/symbol elements become null" {
    const allocator = std.testing.allocator;
    var arr = try JSValue.newArray(allocator);
    defer arr.deinit();
    _ = try arr.array.value.push(JSValue.fromNumber(1.0));
    _ = try arr.array.value.push(JSValue.UNDEFINED);
    _ = try arr.array.value.push(try JSValue.newSymbol(allocator, null));

    const out = try stringify(allocator, arr);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("[1,null,null]", out);
}

test "stringify object: undefined/symbol properties are omitted" {
    const allocator = std.testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    try obj.object.value.set("a", JSValue.fromNumber(1.0));
    try obj.object.value.set("skip", JSValue.UNDEFINED);
    try obj.object.value.set("b", JSValue.fromBool(false));

    const out = try stringify(allocator, obj);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":false}", out);
}

test "stringify regex/map/set/error as {} (no own enumerable properties)" {
    const allocator = std.testing.allocator;

    var m = try JSValue.newMap(allocator);
    defer m.deinit();
    const map_out = try stringify(allocator, m);
    defer allocator.free(map_out);
    try std.testing.expectEqualStrings("{}", map_out);

    var err = try JSValue.newError(allocator, .type_error, "x");
    defer err.deinit();
    const err_out = try stringify(allocator, err);
    defer allocator.free(err_out);
    try std.testing.expectEqualStrings("{}", err_out);
}

test "parse primitives" {
    const allocator = std.testing.allocator;

    var t = try parse(allocator, "true");
    defer t.deinit();
    try std.testing.expect(t.boolean == true);

    var n = try parse(allocator, "  -12.5e2  ");
    defer n.deinit();
    try std.testing.expectEqual(@as(f64, -1250.0), n.number);

    var nl = try parse(allocator, "null");
    defer nl.deinit();
    try std.testing.expect(nl == .@"null");
}

test "parse rejects malformed JSON numbers valid as JS literals" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(JSONError.UnexpectedToken, parse(allocator, "+1"));
    try std.testing.expectError(JSONError.InvalidNumber, parse(allocator, "01"));
    try std.testing.expectError(JSONError.InvalidNumber, parse(allocator, "1."));
    try std.testing.expectError(JSONError.InvalidNumber, parse(allocator, "1e"));
    // "0" parses as a complete, valid number; "x1" is then unconsumed trailing data.
    try std.testing.expectError(JSONError.TrailingData, parse(allocator, "0x1"));
}

test "parse rejects trailing data and dangling commas" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(JSONError.TrailingData, parse(allocator, "1 2"));
    try std.testing.expectError(JSONError.UnexpectedToken, parse(allocator, "[1,]"));
    try std.testing.expectError(JSONError.UnexpectedToken, parse(allocator, "{\"a\":1,}"));
    try std.testing.expectError(JSONError.UnexpectedEnd, parse(allocator, "{\"a\":"));
}

test "parse decodes \\uXXXX escapes and surrogate pairs" {
    const allocator = std.testing.allocator;
    var s = try parse(allocator, "\"\\u0041\\u00e9\"");
    defer s.deinit();
    try std.testing.expectEqualStrings("A\xc3\xa9", s.string.value.data);

    // U+1F600 (grinning face) as a surrogate pair 😀.
    var emoji = try parse(allocator, "\"\\ud83d\\ude00\"");
    defer emoji.deinit();
    try std.testing.expectEqualStrings("\u{1F600}", emoji.string.value.data);
}

test "parse builds a nested tree that frees cleanly with one deinit()" {
    const allocator = std.testing.allocator;
    var v = try parse(allocator,
        \\{"a": [1, 2, {"b": "nested"}], "c": null}
    );
    defer v.deinit();

    try std.testing.expectEqual(@as(usize, 2), v.object.value.size());
    const a = v.object.value.get("a").?;
    try std.testing.expectEqual(@as(usize, 3), a.array.value.length());
}
