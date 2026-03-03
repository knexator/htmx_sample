const std = @import("std");
const httpz = @import("httpz");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Contact = struct {
    id: ?u64 = null,
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

    var server = try httpz.Server(*App).init(allocator, .{ .port = 5882, .request = .{ .max_form_count = 0x100 } }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", getIndex, .{});
    router.get("/contacts", getContacts, .{});
    router.get("/contacts/new", getNewContact, .{});
    router.post("/contacts/new", postNewContact, .{});
    router.get("/contacts/:id", viewContact, .{});
    router.get("/contacts/:id/edit", getEditContact, .{});

    // TODO(platform): general solution for static files
    router.get("/static/site.css", getStatic, .{
        .data = @ptrCast(&@as([]const u8, @embedFile("static/site.css"))),
    });

    std.log.info("Listening at http://localhost:5882", .{});
    try server.listen();
}

const App = struct {
    // TODO(platform): this state should be unique to each user
    contacts: std.ArrayList(Contact),
    // TODO(platform): this is leaking
    pending_flashed_messages: std.ArrayList([]const u8),

    pub fn init(gpa: Allocator) App {
        return .{
            .contacts = .init(gpa),
            .pending_flashed_messages = .init(gpa),
        };
    }

    pub fn deinit(app: *App) void {
        app.contacts.deinit();
        app.pending_flashed_messages.deinit();
    }

    pub fn validate(app: *const App, contact: *Contact) bool {
        if (contact.email == null or contact.email.?.len == 0) {
            contact.errors.email = "Email Required";
        }
        const existing_contact = for (app.contacts.items) |c| {
            if (c.id != contact.id and std.mem.eql(u8, c.email.?, contact.email orelse continue)) {
                break true;
            }
        } else false;
        if (existing_contact) {
            contact.errors.email = "Email Must Be Unique";
        }
        return contact.errors.email == null;
    }

    pub fn save(app: *App, contact: *Contact) !bool {
        if (!app.validate(contact)) {
            return false;
        }
        if (contact.id == null) {
            var max_id: u64 = 1;
            for (app.contacts.items) |c| {
                max_id = @max(max_id, c.id.?);
            }
            contact.id = max_id + 1;
            try app.contacts.append(contact.*);
        }
        // TODO(never)
        // try app.save_db();
        return true;
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

    pub fn find(app: *const App, id: u64) ?Contact {
        for (app.contacts.items) |c| {
            if (c.id.? == id) {
                var result = c;
                result.errors = .{};
                return result;
            }
        } else return null;
    }
};

fn getStatic(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.body = @as(*const []const u8, @alignCast(@ptrCast(req.route_data.?))).*;
}

fn redirect(res: *httpz.Response, url: []const u8) void {
    res.status = 302;
    res.header("Location", url);
}

fn getIndex(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    redirect(res, "/contacts");
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
        .flashed_messages = try app.pending_flashed_messages.toOwnedSlice(),
    });
}

fn getNewContact(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.body = try Templates.newContact(res.arena, .{
        .contact = .{},
        .flashed_messages = try app.pending_flashed_messages.toOwnedSlice(),
    });
}

fn postNewContact(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const form_data = try req.formData();
    var c: Contact = .{
        .id = null,
        .first = form_data.get("first_name"),
        .last = form_data.get("last_name"),
        .phone = form_data.get("phone"),
        .email = form_data.get("email"),
    };
    if (try app.save(&c)) {
        try app.pending_flashed_messages.append("Created New Contact!");
        redirect(res, "/contacts");
    } else {
        res.body = try Templates.newContact(res.arena, .{
            .contact = c,
            .flashed_messages = try app.pending_flashed_messages.toOwnedSlice(),
        });
    }
}

fn getEditContact(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const contact = app.find(try std.fmt.parseInt(u64, req.param("id").?, 10)) orelse return error.ContactNotFound;
    res.body = try Templates.editContact(res.arena, .{
        .contact = contact,
        .flashed_messages = try app.pending_flashed_messages.toOwnedSlice(),
    });
}

fn viewContact(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const contact = app.find(try std.fmt.parseInt(u64, req.param("id").?, 10)) orelse return error.ContactNotFound;
    res.body = try Templates.showContact(res.arena, .{
        .contact = contact,
        .flashed_messages = try app.pending_flashed_messages.toOwnedSlice(),
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
        flashed_messages: []const []const u8,
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
                        .id = contact.id.?,
                        .email = contact.email orelse "",
                        .first = contact.first orelse "",
                        .last = contact.last orelse "",
                        .phone = contact.phone orelse "",
                    });
                }
            }.anon),
        });
        return try layout(arena, .{
            .flashed_messages = params.flashed_messages,
            .content = content,
        });
    }

    pub fn newContact(arena: Allocator, params: struct {
        contact: Contact,
        flashed_messages: []const []const u8,
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
            .flashed_messages = params.flashed_messages,
            .content = content,
        });
    }

    pub fn showContact(arena: Allocator, params: struct {
        contact: Contact,
        flashed_messages: []const []const u8,
    }) ![]const u8 {
        const content = try std.fmt.allocPrint(arena,
            \\ <h1>{[first]s} {[last]s}</h1>
            \\ 
            \\ <div>
            \\     <div>Phone: {[phone]s}</div>
            \\     <div>Email: {[email]s}</div>
            \\ </div>
            \\ 
            \\ <p>
            \\     <a href="/contacts/{[id]d}/edit">Edit</a>
            \\     <a href="/contacts">Back</a>
            \\ </p>
        , .{
            .email = params.contact.email orelse "",
            .first = params.contact.first orelse "",
            .last = params.contact.last orelse "",
            .phone = params.contact.phone orelse "",
            .id = params.contact.id.?,
        });

        return try layout(arena, .{
            .flashed_messages = params.flashed_messages,
            .content = content,
        });
    }

    pub fn editContact(arena: Allocator, params: struct {
        contact: Contact,
        flashed_messages: []const []const u8,
    }) ![]const u8 {
        const content = try std.fmt.allocPrint(arena,
            \\ <form action="/contacts/{[id]d}/edit" method="post">
            \\     <fieldset>
            \\         <legend>Contact Values</legend>
            \\         <div class="table rows">
            \\             <p>
            \\                 <label for="email">Email</label>
            \\                 <input name="email" id="email" type="text" placeholder="Email" value="{[email]s}">
            \\                 <span class="error">{[errors_email]s}</span>
            \\             </p>
            \\             <p>
            \\                 <label for="first_name">First Name</label>
            \\                 <input name="first_name" id="first_name" type="text" placeholder="First Name"
            \\                        value="{[first]s}">
            \\                 <span class="error">{[errors_first]s}</span>
            \\             </p>
            \\             <p>
            \\                 <label for="last_name">Last Name</label>
            \\                 <input name="last_name" id="last_name" type="text" placeholder="Last Name"
            \\                        value="{[last]s}">
            \\                 <span class="error">{[errors_last]s}</span>
            \\             </p>
            \\             <p>
            \\                 <label for="phone">Phone</label>
            \\                 <input name="phone" id="phone" type="text" placeholder="Phone" value="{[phone]s}">
            \\                 <span class="error">{[errors_phone]s}</span>
            \\             </p>
            \\         </div>
            \\         <button>Save</button>
            \\     </fieldset>
            \\ </form>
            \\ 
            \\ <form action="/contacts/{[id]d}/delete" method="post">
            \\     <button>Delete Contact</button>
            \\ </form>
            \\ 
            \\ <p>
            \\     <a href="/contacts">Back</a>
            \\ </p>
        , .{
            .email = params.contact.email orelse "",
            .errors_email = params.contact.errors.email orelse "",
            .first = params.contact.first orelse "",
            .errors_first = params.contact.errors.first orelse "",
            .last = params.contact.last orelse "",
            .errors_last = params.contact.errors.last orelse "",
            .phone = params.contact.phone orelse "",
            .errors_phone = params.contact.errors.phone orelse "",
            .id = params.contact.id.?,
        });

        return try layout(arena, .{
            .flashed_messages = params.flashed_messages,
            .content = content,
        });
    }
};
