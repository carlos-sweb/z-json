const std = @import("std");
const testing = std.testing;
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

fn expectDeepEqual(a: JSValue, b: JSValue) !void {
    try testing.expectEqualStrings(a.typeOf(), b.typeOf());
    switch (a) {
        .@"undefined", .@"null" => {},
        .boolean => try testing.expectEqual(a.boolean, b.boolean),
        .number => try testing.expectEqual(a.number, b.number),
        .string => try testing.expectEqualStrings(a.string.value.data, b.string.value.data),
        .array => {
            try testing.expectEqual(a.array.value.length(), b.array.value.length());
            var i: usize = 0;
            while (i < a.array.value.length()) : (i += 1) {
                try expectDeepEqual(a.array.value.get(i), b.array.value.get(i));
            }
        },
        .object => {
            const keys = try a.object.value.keys(testing.allocator);
            defer testing.allocator.free(keys);
            try testing.expectEqual(a.object.value.size(), b.object.value.size());
            for (keys) |key| {
                try expectDeepEqual(a.object.value.get(key).?, b.object.value.get(key).?);
            }
        },
        else => unreachable,
    }
}

test "round-trip: parse(stringify(v)) deep-equals v for a nested tree" {
    const allocator = testing.allocator;

    var original = try JSValue.newObject(allocator);
    defer original.deinit();
    try original.object.value.set("name", try JSValue.newString(allocator, "z-json"));
    try original.object.value.set("version", JSValue.fromNumber(1.0));
    try original.object.value.set("active", JSValue.fromBool(true));
    try original.object.value.set("tag", JSValue.NULL);

    var tags = try JSValue.newArray(allocator);
    _ = try tags.array.value.push(try JSValue.newString(allocator, "a"));
    _ = try tags.array.value.push(JSValue.fromNumber(2.5));
    try original.object.value.set("tags", tags);

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

    try testing.expectEqualStrings(s.string.value.data, parsed.string.value.data);
}
