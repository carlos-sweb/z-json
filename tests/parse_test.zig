const std = @import("std");
const testing = std.testing;
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "parse array of mixed primitives" {
    const allocator = testing.allocator;
    var v = try zjson.parse(allocator, "[1, \"two\", true, null, false]");
    defer v.deinit();

    try testing.expectEqual(@as(usize, 5), v.asArray().value.length());
    try testing.expectEqual(@as(f64, 1.0), v.asArray().value.get(0).asNumber());
    try testing.expectEqualStrings("two", v.asArray().value.get(1).asString().value.data);
    try testing.expect(v.asArray().value.get(2).asBool() == true);
    try testing.expect(v.asArray().value.get(3).isNull());
    try testing.expect(v.asArray().value.get(4).asBool() == false);
}

test "parse empty array and object" {
    const allocator = testing.allocator;
    var a = try zjson.parse(allocator, "[]");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.asArray().value.length());

    var o = try zjson.parse(allocator, "{}");
    defer o.deinit();
    try testing.expectEqual(@as(usize, 0), o.asObject().value.size());
}

test "parse rejects unterminated string" {
    const allocator = testing.allocator;
    try testing.expectError(zjson.JSONError.UnexpectedEnd, zjson.parse(allocator, "\"abc"));
}

test "parse rejects raw control characters inside a string" {
    const allocator = testing.allocator;
    try testing.expectError(zjson.JSONError.InvalidString, zjson.parse(allocator, "\"a\tb\""));
}
