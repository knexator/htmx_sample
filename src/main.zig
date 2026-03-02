const std = @import("std");
const httpz = @import("httpz");

const assert = std.debug.assert;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{ .port = 5882 }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", getIndex, .{});

    std.log.info("Listening at http://localhost:5882", .{});
    try server.listen();
}

fn getIndex(_: *httpz.Request, res: *httpz.Response) !void {
    try res.writer().writeAll("Hello World!");
}
