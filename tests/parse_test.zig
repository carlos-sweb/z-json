const std = @import("std");
const testing = std.testing;
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "parse array of mixed primitives" {
    const allocator = testing.allocator;
    var v = try zjson.parse(allocator, "[1, \"two\", true, null, false]");
    defer v.deinit();

    try testing.expectEqual(@as(usize, 5), v.array.value.length());
    try testing.expectEqual(@as(f64, 1.0), v.array.value.get(0).number);
    try testing.expectEqualStrings("two", v.array.value.get(1).string.value.data);
    try testing.expect(v.array.value.get(2).boolean == true);
    try testing.expect(v.array.value.get(3) == .@"null");
    try testing.expect(v.array.value.get(4).boolean == false);
}

test "parse empty array and object" {
    const allocator = testing.allocator;
    var a = try zjson.parse(allocator, "[]");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.array.value.length());

    var o = try zjson.parse(allocator, "{}");
    defer o.deinit();
    try testing.expectEqual(@as(usize, 0), o.object.value.size());
}

test "parse rejects unterminated string" {
    const allocator = testing.allocator;
    try testing.expectError(zjson.JSONError.UnexpectedEnd, zjson.parse(allocator, "\"abc"));
}

test "parse rejects raw control characters inside a string" {
    const allocator = testing.allocator;
    try testing.expectError(zjson.JSONError.InvalidString, zjson.parse(allocator, "\"a\tb\""));
}
