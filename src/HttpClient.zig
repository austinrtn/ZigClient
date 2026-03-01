const std = @import("std");
const builtin = @import("builtin");
const PhaseTool = @import("./PhaseTool.zig").PhaseTool;

const ReqErrors = error{
    BadURL,
    RequestSendFailed,
    SendBodilessFailed,
    RecivedHeadersFailed,
    FailedReadingBody,
};

pub fn HttpClient(comptime ContextType: type) type{
    const CtxField:type = if(ContextType == void) void else *ContextType; 
return struct {
    pub const Self = @This();
    pub const Req = std.http.Client.Request;
    pub const Res = std.http.Client.Response;

    pub const Event = struct {
        msg: []const u8,
        ctx: CtxField, 
        onEvent: *const fn(_: *@This()) anyerror!void,
    };

    allocator: std.mem.Allocator,
    ctx: CtxField,
    listeners: std.ArrayList(*EventListener(ContextType)) = .{},

    /// Create new instanceo of HTTPClient 
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

    pub fn get(self: *Self, url: []const u8, req_options: std.http.Client.RequestOptions) (ReqErrors || std.mem.Allocator.Error)!*Response{
        const response_ptr = try self.allocator.create(Response);
        errdefer self.allocator.destroy(response_ptr);
        response_ptr.* = try Response.init(self.allocator, self.stdout, url, req_options);
        errdefer response_ptr.deinit();

        return response_ptr;
    }

    pub fn newEventListener(self: *Self) !*EventListener(ContextType) {
        const event_listener_ptr = try self.allocator.create(EventListener(ContextType));
        event_listener_ptr.* = EventListener(ContextType).init(self.allocator, self);  
        try self.listeners.append(self.allocator, event_listener_ptr);
        return event_listener_ptr;
    }
};}

pub const Response = struct {
    stdout: *std.io.Writer,

    allocator: std.mem.Allocator,
    client: *std.http.Client,
    req: *std.http.Client.Request,
    status: std.http.Status,
    headers: std.StringHashMap([]const u8), 
    body: []const u8,

    pub fn init(allocator: std.mem.Allocator, stdout: *std.io.Writer, url: []const u8, req_options: std.http.Client.RequestOptions) (ReqErrors || std.mem.Allocator.Error)!Response {
        var self: @This() = undefined;
        self.allocator = allocator;
        self.stdout = stdout;


        self.headers = std.StringHashMap([]const u8).init(allocator);

        // New client to make request
        self.client = try allocator.create(std.http.Client);
        errdefer self.allocator.destroy(self.client);
        self.client.* = std.http.Client{.allocator = self.allocator};
        errdefer self.client.deinit();

        self.req = try self.allocator.create(std.http.Client.Request);
        errdefer allocator.destroy(self.req);

        const uri = std.Uri.parse(url) catch return ReqErrors.BadURL;
        self.req.* = self.client.request(.GET, uri, req_options) catch return ReqErrors.RequestSendFailed;
        errdefer self.req.deinit();

        // Send request to server
        var redir_buf: [1024]u8 = undefined; 
        self.req.sendBodiless() catch return ReqErrors.SendBodilessFailed;

        var res = self.req.receiveHead(&redir_buf) catch return ReqErrors.RecivedHeadersFailed;

        var header_iter = res.head.iterateHeaders();
        while(header_iter.next()) |header| {
            try self.headers.put(header.name, header.value);
        }

        self.body = res.reader(&.{}).allocRemaining(self.allocator, .unlimited) catch return ReqErrors.FailedReadingBody;

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.req.deinit(); 
        self.client.deinit();
        self.headers.deinit();

        self.allocator.free(self.body);
        self.allocator.destroy(self.req);
        self.allocator.destroy(self.client);
        self.allocator.destroy(self);
    }
};


pub fn EventListener(comptime ContextType: type) type {
    const HttpClientT = HttpClient(ContextType);
return struct {
    const Self = @This();
    const Event = HttpClientT.Event;

    allocator: std.mem.Allocator,
    http_client: *HttpClientT,
    client: std.http.Client,

    listening: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    req: ?std.http.Client.Request = null,
    thread: ?std.Thread = null,
    events: std.ArrayList(Event) = .{},
    connected: bool = false,


    pub fn init(allocator: std.mem.Allocator, http_client: *HttpClientT) Self {
        return .{
            .allocator = allocator, 
            .http_client = http_client,
            .client = std.http.Client{.allocator = allocator}, 
        };
    }

    pub fn isListening(self: *Self) bool {
        return self.listening.load(.acquire);
    }

    fn setIsListening(self: *Self, val: bool) void {
        self.listening.store(val, .release);
    }

    pub fn newEvent(
        self: *Self, 
        eventMsg: []const u8, 
        comptime onEvent: *const fn(event: *Event) anyerror!void )!void {

        const event = Event{
            .msg = eventMsg, 
            .onEvent = onEvent,
            .ctx = self.http_client.ctx, 
            .stdout = self.http_client.stdout,
        };

        try self.events.append(self.allocator, event);
    }


    pub fn deinit(self: *Self) void {
        const was_running = self.isListening();
        if(self.isListening()) {
            self.stopListening();
            if(builtin.mode == .Debug and was_running) {
                std.debug.print("\nHttpClient.stopListening must be called before deinit\n\n", .{});
                std.debug.assert(!was_running);
            }
        }

        self.events.deinit(self.allocator);
        if(self.req) |*req| req.deinit(); 
        self.client.deinit();
    }

    pub fn listen(self: *Self, url: []const u8) !void {
        const uri = try std.Uri.parse(url);
        var response: ?std.http.Client.Response = null;
        var res_buf: [4096]u8 = undefined;
        var redir_buf: [4096]u8 = undefined;
        var res_reader: ?*std.io.Reader = null;

        self.setIsListening(true);
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
                        if(res.head.status == .ok) self.connected = true else continue;
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
                    try event.onEvent(event);
                }

            } else |err| switch(err) {
                error.EndOfStream, error.ReadFailed => { self.connected = false; }, 
                else => { return err; }
            }
        }
    }

    pub fn startListening(self: *Self, url: []const u8) !void {
        if(self.isListening()) @panic("HttpClient is already listening!  Call HttpClient.stopListening()");

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
