const std = @import("std");
const testing = std.testing;
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "stringify nested array/object matches expected JSON text" {
    const allocator = testing.allocator;
    var arr = try JSValue.newArray(allocator);
    defer arr.deinit();
    _ = try arr.array.value.push(JSValue.fromNumber(1.0));

    var obj = try JSValue.newObject(allocator);
    try obj.object.value.set("nested", arr.retain());
    defer obj.deinit();

    const out = try zjson.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expectEqualStrings("{\"nested\":[1]}", out);
}

test "stringify does not mutate or free its input" {
    const allocator = testing.allocator;
    var s = try JSValue.newString(allocator, "hello");
    defer s.deinit();

    const out1 = try zjson.stringify(allocator, s);
    defer allocator.free(out1);
    const out2 = try zjson.stringify(allocator, s);
    defer allocator.free(out2);
    try testing.expectEqualStrings(out1, out2);
}
