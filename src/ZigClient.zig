const std = @import("std");
const builtin = @import("builtin");

const ReqErrors = error{
    BadURL, // Unable to parse URL to URI 
    RequestSendFailed, // Never reached the server
    SendBodilessFailed, // Was unable to send bodiless request 
    RecivedHeadersFailed,
    FailedReadingBody,
};

pub fn ZigClient(comptime ContextType: type) type{
    const CtxField:type = if(ContextType == void) void else *ContextType; 
return struct {
    pub const Self = @This();
    pub const Res = Response;
    pub const Listener = EventListener(ContextType);

    pub const Event = struct {
        msg: []const u8,
        ctx: CtxField, 
        onEvent: *const fn(_: *@This()) anyerror!void,
        once: bool, 
        triggered: bool = false,
        timeout: u32 = 2000,
    };

    allocator: std.mem.Allocator,
    ctx: CtxField,
    listeners: std.ArrayList(*EventListener(ContextType)) = .{},

    /// Create new instance of HTTPClient 
    pub fn init(allocator: std.mem.Allocator, ctx: CtxField) Self {
        const self: Self = .{
            .allocator = allocator,
            .ctx = ctx,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for(self.listeners.items) |listener| { 
            listener.deinit();
            self.allocator.destroy(listener);
        }
        self.listeners.deinit(self.allocator);
    }

    /// Send GET request to server 
    pub fn get(self: *Self, url: []const u8, req_options: std.http.Client.RequestOptions) (ReqErrors || std.mem.Allocator.Error)!Response{
        return try Response.init(self.allocator, url, req_options);
    }

    /// Spin up new event listener 
    pub fn newEventListener(self: *Self) !*EventListener(ContextType) {
        const event_listener_ptr = try self.allocator.create(EventListener(ContextType));
        event_listener_ptr.* = EventListener(ContextType).init(self.allocator, self);  
        try self.listeners.append(self.allocator, event_listener_ptr);
        return event_listener_ptr;
    }
};}


pub const Response = struct {
    arena: std.heap.ArenaAllocator,
    client: *std.http.Client,

    req: *std.http.Client.Request,
    status: std.http.Status,

    headers: []std.http.Header,
    body: []const u8,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, req_options: std.http.Client.RequestOptions) (ReqErrors || std.mem.Allocator.Error)!Response {
        var self: @This() = undefined;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const arena_alloc = self.arena.allocator();

        var header_list = std.ArrayList(std.http.Header){};
        defer header_list.deinit(arena_alloc);

        // New client to make request
        self.client = try arena_alloc.create(std.http.Client);
        self.client.* = std.http.Client{.allocator = arena_alloc};
        errdefer self.client.deinit();

        self.req = try arena_alloc.create(std.http.Client.Request);
        const uri = std.Uri.parse(url) catch return ReqErrors.BadURL;
        self.req.* = self.client.request(.GET, uri, req_options) catch return ReqErrors.RequestSendFailed;
        errdefer self.req.deinit();

        // Send request to server
        var redir_buf: [1024]u8 = undefined; 
        self.req.sendBodiless() catch return ReqErrors.SendBodilessFailed;

        var res = self.req.receiveHead(&redir_buf) catch return ReqErrors.RecivedHeadersFailed;

        // Obtain headers and store in hashmap 
        var header_iter = res.head.iterateHeaders();
        while(header_iter.next()) |header| {
            try header_list.append( 
                arena_alloc, 
                std.http.Header{
                    .name = try arena_alloc.dupe(u8, header.name),
                    .value = try arena_alloc.dupe(u8, header.value),
                },
            );
        }

        self.status = res.head.status;
        self.headers = try header_list.toOwnedSlice(arena_alloc);
        self.body = res.reader(&.{}).allocRemaining(arena_alloc, .unlimited) catch return ReqErrors.FailedReadingBody;

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.req.deinit();
        self.arena.deinit();
    }

    pub fn getHeader(self: *@This(), header_key: []const u8) ?[]const u8 {
        for(self.headers) |header| {
            if(std.mem.eql(u8, header.name, header_key)) { return header.value; }
        }
        return null;
    }
};

pub fn EventListener(comptime ContextType: type) type {
    const ZigClientT = ZigClient(ContextType);
return struct {
    const Self = @This();
    const Event = ZigClientT.Event;

    allocator: std.mem.Allocator,
    http_client: *ZigClientT,
    client: std.http.Client,

    listening: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    req: ?std.http.Client.Request = null,
    thread: ?std.Thread = null,
    events: std.ArrayList(Event) = .{},
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, http_client: *ZigClientT) Self {
        return .{
            .allocator = allocator, 
            .http_client = http_client,
            .client = std.http.Client{.allocator = allocator}, 
        };
    }

    pub fn deinit(self: *Self) void {
        const was_running = self.isListening();
        if(self.isListening()) {
            self.stopListening();
            if(builtin.mode == .Debug and was_running) {
                std.debug.print("\nZigClient.stopListening must be called before deinit\n\n", .{});
                std.debug.assert(!was_running);
            }
        }

        self.events.deinit(self.allocator);
        if(self.req) |*req| req.deinit(); 
        self.client.deinit();
    }

    pub fn isListening(self: *Self) bool {
        return self.listening.load(.acquire);
    }

    /// Use the Event Message of a one time Event to reset it so it can be listened for by the server again  
    pub fn resetEvent(self: *Self, event_msg: []const u8) void {
        for(self.events.items) |*event| {
            if(std.mem.eql(u8, event.msg, event_msg)) {
                event.triggered = false;
                return;
            }
        }
    }

    /// Reset all one time events so that they can be listened for by the server again
    pub fn resetAllEvents(self: *Self) void {
        for(self.events.items) |*event| {
            event.triggered = false;
        }
    }

    /// Not for API use
    fn setIsListening(self: *Self, val: bool) void {
        self.listening.store(val, .release);
    }

    pub fn newEvent(
        self: *Self, 
        eventMsg: []const u8, 
        once: bool,
        comptime onEvent: *const fn(event: *Event) anyerror!void )!void {

        const event = Event{
            .msg = eventMsg, 
            .once = once,
            .onEvent = onEvent,
            .ctx = self.http_client.ctx, 
        };

        try self.events.append(self.allocator, event);
    }

    pub fn listen(self: *Self, url: []const u8) !void {
        const uri = try std.Uri.parse(url);
        var response: ?std.http.Client.Response = null;
        var res_buf: [4096]u8 = undefined;
        var redir_buf: [4096]u8 = undefined;
        var res_reader: ?*std.io.Reader = null;

        while(true) {
            if(!self.isListening()) break;

            if(!self.connected or self.req == null or response == null) {
                if(self.client.request(.GET, uri, .{})) 
                    |req| { self.req = req; }
                else |err| switch(err) {
                    error.ConnectionRefused => { 
                        self.connected = false; 
                        self.req = null; 
                    },
                    else => { return err; }
                }

                if(self.req) |*req| {
                    req.sendBodiless() catch continue;
                    if(req.receiveHead(&redir_buf)) |res| { 
                        response = res; 
                    } 
                    else |err| switch (err) {
                        error.ConnectionRefused, error.HttpConnectionClosing => {
                            self.connected = false;
                            req.deinit();
                            self.req = null;
                        },
                        else => { return err; }
                    }

                    if(response) |*res| {
                        if(res.head.status == .ok){
                            self.connected = true;
                            self.resetAllEvents();
                        }  else continue;

                        res_reader = res.reader(&res_buf);
                    } else continue; 
                } else continue;
            }

            if(!self.connected) continue;
            while (res_reader.?.takeDelimiterInclusive('\n')) |line| {
                if(!self.isListening()) break;
                if(line.len == 0) continue;
                const server_msg = std.mem.trimRight(u8, line, "\n");

                for(self.events.items) |*event| {
                    if(!std.mem.eql(u8, event.msg, server_msg)) continue;
                    if(event.once and event.triggered) continue;

                    try event.onEvent(event);
                    if(event.once) event.triggered = true;
                }

            } else |err| switch(err) {
                error.EndOfStream, error.ReadFailed => { self.connected = false; }, 
                else => { return err; }
            }
        }
    }

    pub fn startListening(self: *Self, url: []const u8) !void {
        if(self.isListening()) @panic("ZigClient is already listening!  Call ZigClient.stopListening()");

        self.setIsListening(true);
        self.thread = try std.Thread.spawn(.{}, Self.listen, .{self, url}); 
    }

    pub fn stopListening(self: *Self) void {
        self.setIsListening(false);
        self.connected = false;
        if(self.req) |*req| {
            if(req.connection) |conn| {
                const stream = conn.stream_reader.getStream().handle;
                std.posix.shutdown(stream, .recv) catch {};
            }
        }
        if(self.thread) |thread| { thread.join(); }
        if(self.req) |*req| { req.deinit(); }

        self.req = null;
        self.thread = null;
    }
};
}
