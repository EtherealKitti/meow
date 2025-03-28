const std = @import("std");
const zjb = @import("zjb");

export fn main() void {
    zjb.global("console").call("log",.{zjb.constString("Meow :3")},void);
}