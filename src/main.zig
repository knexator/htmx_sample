const std = @import("std");
const httpz = @import("httpz");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Contact = struct {
    id: u32,
    first: ?[]const u8 = null,
    last: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    email: ?[]const u8 = null,
    errors: struct {
        first: ?[]const u8 = null,
        last: ?[]const u8 = null,
        phone: ?[]const u8 = null,
        email: ?[]const u8 = null,
    } = .{},
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var app: App = .init(allocator);
    defer app.deinit();

    try app.contacts.appendSlice(&.{
        .{
            .id = 2,
            .first = "Carson",
            .last = "Gross",
            .phone = "123-456-7890",
            .email = "carson@example.comz",
        },
        .{
            .id = 3,
            .first = "",
            .last = "",
            .phone = "",
            .email = "joe@example.com",
        },
        .{
            .id = 4,
            .first = "",
            .last = "",
            .phone = "",
            .email = "carson@example.com",
        },
        .{
            .id = 5,
            .first = "Michael",
            .last = "Kennedy",
            .phone = "7227777777",
            .email = "michael@mkennedy.tech",
        },
        .{
            .id = 6,
            .first = "Jeff",
            .last = "J",
            .phone = "7760909997",
            .email = "jeff@jeff.com",
        },
    });

    var server = try httpz.Server(*App).init(allocator, .{ .port = 5882 }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", getIndex, .{});
    router.get("/contacts", getContacts, .{});
    router.get("/contacts/new", getNewContact, .{});

    // TODO(platform): general solution for static files
    router.get("/static/site.css", getStatic, .{
        .data = @ptrCast(&@as([]const u8, @embedFile("static/site.css"))),
    });

    std.log.info("Listening at http://localhost:5882", .{});
    try server.listen();
}

const App = struct {
    contacts: std.ArrayList(Contact),

    pub fn init(gpa: Allocator) App {
        return .{ .contacts = .init(gpa) };
    }

    pub fn deinit(app: *App) void {
        app.contacts.deinit();
    }

    pub fn search(app: *const App, allocator: Allocator, query: []const u8) ![]Contact {
        var result: std.ArrayListUnmanaged(Contact) = .empty;
        for (app.contacts.items) |contact| {
            if (query.len == 0 or
                std.mem.containsAtLeast(u8, contact.first orelse "", 1, query) or
                std.mem.containsAtLeast(u8, contact.last orelse "", 1, query) or
                std.mem.containsAtLeast(u8, contact.email orelse "", 1, query) or
                std.mem.containsAtLeast(u8, contact.phone orelse "", 1, query))
            {
                try result.append(allocator, contact);
            }
        }
        return try result.toOwnedSlice(allocator);
    }
};

fn getStatic(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.body = @as(*const []const u8, @alignCast(@ptrCast(req.route_data.?))).*;
}

fn getIndex(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 302;
    res.header("Location", "/contacts");
}

fn getContacts(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const contacts: []const Contact =
        if (query.get("q")) |search|
            try app.search(res.arena, search)
        else
            app.contacts.items;

    res.body = try Templates.contacts(res.arena, .{
        .contacts = contacts,
        .search_query = query.get("q"),
    });
}

fn getNewContact(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.body = try Templates.newContact(res.arena, .{
        .contact = .{ .id = undefined },
    });
}

const Templates = struct {
    fn loop(arena: Allocator, values: []const []const u8, comptime format: []const u8) ![]const u8 {
        var buffer: std.ArrayList(u8) = .init(arena);
        for (values) |value| {
            try buffer.writer().print(format, .{value});
        }
        return try buffer.toOwnedSlice();
    }

    fn loop2(arena: Allocator, comptime T: type, values: []const T, comptime format: []const u8) ![]const u8 {
        var buffer: std.ArrayList(u8) = .init(arena);
        for (values) |value| {
            try buffer.writer().print(format, value);
        }
        return try buffer.toOwnedSlice();
    }

    fn loop3(arena: Allocator, comptime T: type, values: []const T, comptime mapper: fn (allocator: Allocator, element: T) error{OutOfMemory}![]const u8) ![]const u8 {
        var buffer: std.ArrayList(u8) = .init(arena);
        for (values) |value| {
            try buffer.appendSlice(try mapper(arena, value));
        }
        return try buffer.toOwnedSlice();
    }

    pub fn layout(arena: Allocator, params: struct {
        flashed_messages: []const []const u8,
        content: []const u8,
    }) ![]const u8 {
        return std.fmt.allocPrint(arena,
            \\ <!doctype html>
            \\ <html lang="">
            \\ <head>
            \\     <title>Contact App</title>
            \\     <link rel="stylesheet" href="https://unpkg.com/missing.css@1.2.0">
            \\     <link rel="stylesheet" href="/static/site.css">
            \\ </head>
            \\ <body>
            \\ <main hx-indicator="#indicator">
            \\     <header>
            \\         <h1>
            \\             <all-caps>contacts.app</all-caps>
            \\             <sub-title>A Demo Contacts Application</sub-title>
            \\         </h1>
            \\     </header>
            \\     {[flashed_messages]s}
            \\     {[content]s}
            \\ </main>
            \\ </body>
            \\ </html>
        , .{
            .content = params.content,
            .flashed_messages = try loop(arena, params.flashed_messages,
                \\ <div class="flash">{s}</div>
            ),
        });
    }

    pub fn contacts(arena: Allocator, params: struct {
        search_query: ?[]const u8,
        contacts: []const Contact,
    }) ![]const u8 {
        const content = try std.fmt.allocPrint(arena,
            \\    <form action="/contacts" method="get">
            \\        <fieldset>
            \\            <legend>Contact Search</legend>
            \\            <p>
            \\                <label for="search">Search Term</label>
            \\                <input id="search" type="search" name="q" value="{[search_query]s}"/>
            \\            </p>
            \\            <p>
            \\                <input type="submit" value="Search"/>
            \\            </p>
            \\        </fieldset>
            \\    </form>
            \\
            \\    <table>
            \\        <thead>
            \\        <tr>
            \\            <th>First</th>
            \\            <th>Last</th>
            \\            <th>Phone</th>
            \\            <th>Email</th>
            \\            <th></th>
            \\        </tr>
            \\        </thead>
            \\        <tbody>
            \\        {[contacts]s}
            \\        </tbody>
            \\    </table>
            \\
            \\    <p>
            \\        <a href="/contacts/new">Add Contact</a>
            \\    </p>
        , .{
            .search_query = params.search_query orelse "",
            .contacts = try loop3(arena, Contact, params.contacts, struct {
                fn anon(allocator: Allocator, contact: Contact) ![]const u8 {
                    return try std.fmt.allocPrint(allocator,
                        \\            <tr>
                        \\                <td>{[email]s}</td>
                        \\                <td>{[first]s}</td>
                        \\                <td>{[last]s}</td>
                        \\                <td>{[phone]s}</td>
                        \\                <td><a href="/contacts/{[id]d}/edit">Edit</a> <a href="/contacts/{[id]d}">View</a></td>
                        \\            </tr>
                    , .{
                        .id = contact.id,
                        .email = contact.email orelse "",
                        .first = contact.first orelse "",
                        .last = contact.last orelse "",
                        .phone = contact.phone orelse "",
                    });
                }
            }.anon),
        });
        return try layout(arena, .{
            .flashed_messages = &.{},
            .content = content,
        });
    }

    pub fn newContact(arena: Allocator, params: struct {
        contact: Contact,
    }) ![]const u8 {
        const content = try std.fmt.allocPrint(arena,
            \\<form action="/contacts/new" method="post">
            \\    <fieldset>
            \\        <legend>Contact Values</legend>
            \\        <div class="table rows">
            \\            <p>
            \\                <label for="email">Email</label>
            \\                <input name="email" id="email" type="text" placeholder="Email" value="{[email]s}">
            \\                <span class="error">{[errors_email]s}</span>
            \\            </p>
            \\            <p>
            \\                <label for="first_name">First Name</label>
            \\                <input name="first_name" id="first_name" type="text" placeholder="First Name" value="{[first]s}">
            \\                <span class="error">{[errors_first]s}</span>
            \\            </p>
            \\            <p>
            \\                <label for="last_name">Last Name</label>
            \\                <input name="last_name" id="last_name" type="text" placeholder="Last Name" value="{[last]s}">
            \\                <span class="error">{[errors_last]s}</span>
            \\            </p>
            \\            <p>
            \\                <label for="phone">Phone</label>
            \\                <input name="phone" id="phone" type="text" placeholder="Phone" value="{[phone]s}">
            \\                <span class="error">{[errors_phone]s}</span>
            \\            </p>
            \\        </div>
            \\        <button>Save</button>
            \\    </fieldset>
            \\</form>
            \\
            \\<p>
            \\    <a href="/contacts">Back</a>
            \\</p>
        , .{
            .email = params.contact.email orelse "",
            .errors_email = params.contact.errors.email orelse "",
            .first = params.contact.first orelse "",
            .errors_first = params.contact.errors.first orelse "",
            .last = params.contact.last orelse "",
            .errors_last = params.contact.errors.last orelse "",
            .phone = params.contact.phone orelse "",
            .errors_phone = params.contact.errors.phone orelse "",
        });

        return try layout(arena, .{
            .flashed_messages = &.{},
            .content = content,
        });
    }
};
