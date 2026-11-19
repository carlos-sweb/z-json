const std = @import("std");
const testing = std.testing;
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

fn expectDeepEqual(a: JSValue, b: JSValue) !void {
    try testing.expectEqualStrings(a.typeOf(), b.typeOf());
    switch (a.tag()) {
        .undefined, .null => {},
        .boolean => try testing.expectEqual(a.asBool(), b.asBool()),
        .number => try testing.expectEqual(a.asNumber(), b.asNumber()),
        .string => try testing.expectEqualStrings(a.asString().value.data, b.asString().value.data),
        .array => {
            try testing.expectEqual(a.asArray().value.length(), b.asArray().value.length());
            var i: usize = 0;
            while (i < a.asArray().value.length()) : (i += 1) {
                try expectDeepEqual(a.asArray().value.get(i), b.asArray().value.get(i));
            }
        },
        .object => {
            const keys = try a.asObject().value.keys(testing.allocator);
            defer testing.allocator.free(keys);
            try testing.expectEqual(a.asObject().value.size(), b.asObject().value.size());
            for (keys) |key| {
                try expectDeepEqual(a.asObject().value.get(key).?, b.asObject().value.get(key).?);
            }
        },
        else => unreachable,
    }
}

test "round-trip: parse(stringify(v)) deep-equals v for a nested tree" {
    const allocator = testing.allocator;

    var original = try JSValue.newObject(allocator);
    defer original.deinit();
    try original.asObject().value.set("name", try JSValue.newString(allocator, "z-json"));
    try original.asObject().value.set("version", JSValue.fromNumber(1.0));
    try original.asObject().value.set("active", JSValue.fromBool(true));
    try original.asObject().value.set("tag", JSValue.NULL);

    var tags = try JSValue.newArray(allocator);
    _ = try tags.asArray().value.push(try JSValue.newString(allocator, "a"));
    _ = try tags.asArray().value.push(JSValue.fromNumber(2.5));
    try original.asObject().value.set("tags", tags);

    const text = try zjson.stringify(allocator, original);
    defer allocator.free(text);

    var parsed = try zjson.parse(allocator, text);
    defer parsed.deinit();

    try expectDeepEqual(original, parsed);
}

test "round-trip preserves escaped string content" {
    const allocator = testing.allocator;
    var s = try JSValue.newString(allocator, "line1\nline2\t\"quoted\"\\backslash");
    defer s.deinit();

    const text = try zjson.stringify(allocator, s);
    defer allocator.free(text);

    var parsed = try zjson.parse(allocator, text);
    defer parsed.deinit();

    try testing.expectEqualStrings(s.asString().value.data, parsed.asString().value.data);
}
