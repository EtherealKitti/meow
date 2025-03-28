const std = @import("std");

pub fn string(b: []const u8) Handle {
    if (b.len == 0) {
        return @enumFromInt(2);
    }
    return zjb.string(b.ptr, b.len);
}

pub fn constString(comptime b: []const u8) ConstHandle {
    return struct {
        var handle: ?ConstHandle = null;
        fn get() ConstHandle {
            if (handle) |h| {
                return h;
            }
            ConstHandle.handle_count += 1;
            handle = @enumFromInt(@intFromEnum(string(b)));
            return handle.?;
        }
    }.get();
}

pub fn global(comptime b: []const u8) ConstHandle {
    return struct {
        var handle: ?ConstHandle = null;
        fn get() ConstHandle {
            if (handle) |h| {
                return h;
            }
            ConstHandle.handle_count += 1;
            handle = @enumFromInt(@intFromEnum(ConstHandle.global.get(b, Handle)));
            return handle.?;
        }
    }.get();
}

pub fn fnHandle(comptime name: []const u8, comptime f: anytype) ConstHandle {
    comptime exportFn(name, f);

    return struct {
        var handle: ?ConstHandle = null;
        fn get() ConstHandle {
            if (handle) |h| {
                return h;
            }
            ConstHandle.handle_count += 1;
            handle = @enumFromInt(@intFromEnum(ConstHandle.exports.get(name, Handle)));
            return handle.?;
        }
    }.get();
}

pub fn exportGlobal(comptime name: []const u8, comptime value: anytype) void {
    const T = @TypeOf(value.*);
    validateGlobalType(T);

    return @export(value, .{ .name = "zjb_global_" ++ @typeName(T) ++ "_" ++ name });
}

pub fn exportFn(comptime name: []const u8, comptime f: anytype) void {
    comptime var export_name: []const u8 = "zjb_fn_";
    const type_info = @typeInfo(@typeInfo(@TypeOf(f)).pointer.child).@"fn";
    validateToJavascriptReturnType(type_info.return_type orelse void);
    inline for (type_info.params) |param| {
        validateFromJavascriptArgumentType(param.type orelse void);
        export_name = export_name ++ comptime shortTypeName(param.type orelse @compileError("zjb exported functions need specified types."));
    }
    export_name = export_name ++ "_" ++ comptime shortTypeName(type_info.return_type orelse null) ++ "_" ++ name;

    @export(f, .{ .name = export_name });
}

pub fn panic(msg: []const u8, stacktrace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = stacktrace;
    _ = ret_addr;

    const handle = string(msg);
    global("console").call("error", .{ constString("Zjb panic handler called with message: "), handle }, void);
    throwAndRelease(handle);
}

pub fn unreleasedHandleCount() u32 {
    return zjb.handleCount() - ConstHandle.handle_count;
}

pub fn throwError(err: anyerror) noreturn {
    const handle = string(@errorName(err));
    throwAndRelease(handle);
}

pub extern "zjb" fn throw(handle: Handle) noreturn;
pub extern "zjb" fn throwAndRelease(handle: Handle) noreturn;

pub fn i8ArrayView(data: []const i8) Handle {
    return zjb.i8ArrayView(data.ptr, data.len);
}
pub fn u8ArrayView(data: []const u8) Handle {
    return zjb.u8ArrayView(data.ptr, data.len);
}
pub fn u8ClampedArrayView(data: []const u8) Handle {
    return zjb.u8ClampedArrayView(data.ptr, data.len);
}

pub fn dataView(data: anytype) Handle {
    switch (@typeInfo(@TypeOf(data))) {
        .pointer => |ptr| {
            if (ptr.size == .one) {
                return zjb.dataview(data, @sizeOf(ptr.child));
            } else if (ptr.size == .slice) {
                return zjb.dataview(data.ptr, data.len * @sizeOf(ptr.child));
            } else {
                @compileError("dataview pointers must be single objects or slices, got: " ++ @typeName(@TypeOf(data)));
            }
        },
        else => {
            @compileError("dataview must get a pointer or a slice, got: " ++ @typeName(@TypeOf(data)));
        },
    }
}

pub const ConstHandle = enum(i32) {
    null = 0,
    global = 1,
    empty_string = 2,
    exports = 3,
    _,

    var handle_count: u32 = 4;

    pub fn isNull(handle: ConstHandle) bool {
        return handle == .null;
    }

    fn asHandle(handle: ConstHandle) Handle {
        // Generally not a safe conversion, as turning into a handle and releasing elsewhere
        // will invalidate all other uses of the constant.
        return @enumFromInt(@intFromEnum(handle));
    }

    pub fn get(handle: ConstHandle, comptime field: []const u8, comptime RetType: type) RetType {
        return handle.asHandle().get(field, RetType);
    }
    pub fn set(handle: ConstHandle, comptime field: []const u8, value: anytype) void {
        handle.asHandle().set(field, value);
    }
    pub fn indexGet(handle: ConstHandle, arg: anytype, comptime RetType: type) RetType {
        return handle.asHandle().indexGet(arg, RetType);
    }
    pub fn indexSet(handle: ConstHandle, arg: anytype, value: anytype) void {
        handle.asHandle().indexSet(arg, value);
    }
    pub fn eql(handle: Handle, other: anytype) bool {
        handle.asHandle().equal(other);
    }
    pub fn call(handle: ConstHandle, comptime method: []const u8, args: anytype, comptime RetType: type) RetType {
        return handle.asHandle().call(method, args, RetType);
    }
    pub fn new(handle: ConstHandle, args: anytype) Handle {
        return handle.asHandle().new(args);
    }
};

pub const Handle = enum(i32) {
    null = 0,
    _,

    pub fn isNull(handle: Handle) bool {
        return handle == .null;
    }

    pub fn release(handle: Handle) void {
        if (@intFromEnum(handle) > 2) {
            zjb.release(handle);
        }
    }

    pub fn get(handle: Handle, comptime field: []const u8, comptime RetType: type) RetType {
        validateFromJavascriptReturnType(RetType);
        const name = comptime "get_" ++ shortTypeName(RetType) ++ "_" ++ field;
        const F = fn (Handle) callconv(.C) mapType(RetType);
        const f = @extern(*const F, .{ .library_name = "zjb", .name = name });
        return @call(.auto, f, .{handle});
    }

    pub fn set(handle: Handle, comptime field: []const u8, value: anytype) void {
        validateToJavascriptArgumentType(@TypeOf(value));
        const name = comptime "set_" ++ shortTypeName(@TypeOf(value)) ++ "_" ++ field;
        const F = fn (mapType(@TypeOf(value)), Handle) callconv(.C) void;
        const f = @extern(*const F, .{ .library_name = "zjb", .name = name });
        @call(.auto, f, .{ value, handle });
    }

    pub fn indexGet(handle: Handle, arg: anytype, comptime RetType: type) RetType {
        validateToJavascriptArgumentType(@TypeOf(arg));
        validateFromJavascriptReturnType(RetType);
        const name = comptime "indexGet_" ++ shortTypeName(@TypeOf(arg)) ++ "_" ++ shortTypeName(RetType);
        const F = fn (mapType(@TypeOf(arg)), Handle) callconv(.C) mapType(RetType);
        const f = @extern(*const F, .{ .library_name = "zjb", .name = name });
        return @call(.auto, f, .{ arg, handle });
    }

    pub fn indexSet(handle: Handle, arg: anytype, value: anytype) void {
        validateToJavascriptArgumentType(@TypeOf(arg));
        validateToJavascriptArgumentType(@TypeOf(value));
        const name = comptime "indexSet_" ++ shortTypeName(@TypeOf(arg)) ++ shortTypeName(@TypeOf(value));
        const F = fn (mapType(@TypeOf(arg)), mapType(@TypeOf(value)), Handle) callconv(.C) void;
        const f = @extern(*const F, .{ .library_name = "zjb", .name = name });
        @call(.auto, f, .{ arg, value, handle });
    }

    pub fn eql(handle: Handle, other: anytype) bool {
        switch (@TypeOf(other)) {
            Handle => return zjb.equal(handle, other),
            ConstHandle => return zjb.equal(handle, other.asHandle()),
            else => @compileError("eql only compares against Handle and ConstHandle, not " ++ @typeName(@TypeOf(other))),
        }
    }

    pub fn call(handle: Handle, comptime method: []const u8, args: anytype, comptime RetType: type) RetType {
        return handle.invoke(args, RetType, "call_", "_" ++ method);
    }

    pub fn new(handle: Handle, args: anytype) Handle {
        return handle.invoke(args, Handle, "new_", "");
    }

    fn invoke(handle: Handle, args: anytype, comptime RetType: type, comptime prefix: []const u8, comptime suffix: []const u8) RetType {
        validateFromJavascriptReturnType(RetType);
        const fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
        comptime var call_params: [fields.len + 1]std.builtin.Type.Fn.Param = undefined;
        comptime var extern_name: []const u8 = prefix;

        call_params[fields.len] = .{
            .is_generic = false,
            .is_noalias = false,
            .type = Handle,
        };

        inline for (fields, 0..) |field, i| {
            validateToJavascriptArgumentType(field.type);
            call_params[i] = .{
                .is_generic = false,
                .is_noalias = false,
                .type = mapType(field.type),
            };
            extern_name = extern_name ++ comptime shortTypeName(field.type);
        }

        const F = @Type(.{ .@"fn" = .{
            .calling_convention = .C,
            .is_generic = false,
            .is_var_args = false,
            .return_type = RetType,
            .params = &call_params,
        } });
        extern_name = extern_name ++ "_" ++ comptime shortTypeName(RetType) ++ suffix;

        const f = @extern(*const F, .{ .library_name = "zjb", .name = extern_name });
        return @call(.auto, f, args ++ .{handle});
    }
};

fn validateToJavascriptArgumentType(comptime T: type) void {
    switch (T) {
        Handle, ConstHandle, bool, i32, i64, f32, f64, comptime_int, comptime_float => {},
        else => @compileError("unexpected type " ++ @typeName(T) ++ ". Supported types here: zjb.Handle, zjb.ConstHandle, bool, i32, i64, f32, f64, comptime_int, comptime_float."),
    }
}

fn validateToJavascriptReturnType(comptime T: type) void {
    switch (T) {
        Handle, ConstHandle, bool, i32, i64, f32, f64, void => {},
        else => @compileError("unexpected type " ++ @typeName(T) ++ ". Supported types here: zjb.Handle, zjb.ConstHandle, bool, i32, i64, f32, f64, void."),
    }
}

fn validateFromJavascriptReturnType(comptime T: type) void {
    switch (T) {
        Handle, bool, i32, i64, f32, f64, void => {},
        else => @compileError("unexpected type " ++ @typeName(T) ++ ". Supported types here: zjb.Handle, bool, i32, i64, f32, f64, void."),
    }
}

fn validateFromJavascriptArgumentType(comptime T: type) void {
    switch (T) {
        Handle, bool, i32, i64, f32, f64 => {},
        else => @compileError("unexpected type " ++ @typeName(T) ++ ". Supported types here: zjb.Handle, bool, i32, i64, f32, f64."),
    }
}

fn validateGlobalType(comptime T: type) void {
    switch (T) {
        bool, i32, i64, u32, u64, f32, f64 => {},
        else => @compileError("unexpected type " ++ @typeName(T) ++ ". Supported types here: bool, i32, i64, u32, u64, f32, f64."),
    }
}

fn shortTypeName(comptime T: type) []const u8 {
    return switch (T) {
        Handle, ConstHandle => "o",
        void => "v",
        bool => "b",
        // // The number types map to the same name, even though
        // // the function signatures are different.  Zig and Wasm
        // // handle this just fine, and produces fewer unique methods
        // // in javascript so there's no reason not to do it.
        // i32, i64, f32, f64, comptime_int, comptime_float => "n",

        // The above should be true, but 0.14.0 broke it.  See https://github.com/scottredig/zig-javascript-bridge/issues/14
        i32 => "i32",
        i64 => "i64",
        f32 => "f32",
        f64, comptime_float, comptime_int => "f64",

        else => unreachable,
    };
}

fn mapType(comptime T: type) type {
    if (T == comptime_float or T == comptime_int) {
        return f64;
    }
    return T;
}

const zjb = struct {
    extern "zjb" fn release(id: Handle) void;
    extern "zjb" fn string(ptr: [*]const u8, len: u32) Handle;
    extern "zjb" fn dataview(ptr: *const anyopaque, size: u32) Handle;
    extern "zjb" fn throwAndRelease(id: Handle) void;
    extern "zjb" fn equal(handle: Handle, other: Handle) bool;
    extern "zjb" fn handleCount() u32;

    extern "zjb" fn i8ArrayView(ptr: *const anyopaque, size: u32) Handle;
    extern "zjb" fn u8ArrayView(ptr: *const anyopaque, size: u32) Handle;
    extern "zjb" fn u8ClampedArrayView(ptr: *const anyopaque, size: u32) Handle;
};
