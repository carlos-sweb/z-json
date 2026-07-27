const std = @import("std");
const testing = std.testing;
const zjson = @import("zjson");
const zvalue = @import("zvalue");
const zbuffer = @import("zbuffer");
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

test "stringify TypedArray serializes indexed elements like real Node" {
    const allocator = testing.allocator;
    const buf = try JSValue.newArrayBuffer(allocator, 12);
    const view = try zbuffer.TypedArrayView(i32).init(&buf.array_buffer.value, 0, 3);
    try view.set(0, 1);
    try view.set(1, 2);
    try view.set(2, 3);
    const ta = try JSValue.newTypedArray(allocator, buf, 0, 3, .i32);
    defer ta.deinit();

    const out = try zjson.stringify(allocator, ta);
    defer allocator.free(out);
    try testing.expectEqualStrings("{\"0\":1,\"1\":2,\"2\":3}", out);
}

test "stringify Float64Array preserves fractional/negative values" {
    const allocator = testing.allocator;
    const buf = try JSValue.newArrayBuffer(allocator, 16);
    const view = try zbuffer.TypedArrayView(f64).init(&buf.array_buffer.value, 0, 2);
    try view.set(0, 1.5);
    try view.set(1, -2.5);
    const ta = try JSValue.newTypedArray(allocator, buf, 0, 2, .f64);
    defer ta.deinit();

    const out = try zjson.stringify(allocator, ta);
    defer allocator.free(out);
    try testing.expectEqualStrings("{\"0\":1.5,\"1\":-2.5}", out);
}

test "stringify empty TypedArray gives {}" {
    const allocator = testing.allocator;
    const buf = try JSValue.newArrayBuffer(allocator, 0);
    const ta = try JSValue.newTypedArray(allocator, buf, 0, 0, .u8);
    defer ta.deinit();

    const out = try zjson.stringify(allocator, ta);
    defer allocator.free(out);
    try testing.expectEqualStrings("{}", out);
}

test "stringify BigInt64Array/BigUint64Array throws Unserializable" {
    const allocator = testing.allocator;
    const buf = try JSValue.newArrayBuffer(allocator, 8);
    const view = try zbuffer.TypedArrayView(i64).init(&buf.array_buffer.value, 0, 1);
    try view.set(0, 1);
    const ta = try JSValue.newTypedArray(allocator, buf, 0, 1, .i64);
    defer ta.deinit();

    try testing.expectError(zjson.JSONError.Unserializable, zjson.stringify(allocator, ta));
}

test "stringify TypedArray nested in array/object" {
    const allocator = testing.allocator;
    const buf = try JSValue.newArrayBuffer(allocator, 8);
    const view = try zbuffer.TypedArrayView(i32).init(&buf.array_buffer.value, 0, 2);
    try view.set(0, 9);
    try view.set(1, 8);
    const ta = try JSValue.newTypedArray(allocator, buf, 0, 2, .i32);

    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    try obj.object.value.set("a", ta);

    const out = try zjson.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expectEqualStrings("{\"a\":{\"0\":9,\"1\":8}}", out);
}

test "stringify Uint8ClampedArray reads through the same u8 storage as Uint8Array" {
    const allocator = testing.allocator;
    const buf = try JSValue.newArrayBuffer(allocator, 2);
    const view = try zbuffer.TypedArrayView(u8).init(&buf.array_buffer.value, 0, 2);
    try view.set(0, 255);
    try view.set(1, 0);
    const ta = try JSValue.newTypedArray(allocator, buf, 0, 2, .u8_clamped);
    defer ta.deinit();

    const out = try zjson.stringify(allocator, ta);
    defer allocator.free(out);
    try testing.expectEqualStrings("{\"0\":255,\"1\":0}", out);
}
