const std = @import("std");
const Client = @import("ZigClient.zig");
const ZigClient = Client.ZigClient(Context);

///*******************************************************
///************ ZIG HTTP CLIENT TOOL *********************
///*******************************************************
/// This tool allows users to send simple get requests to 
/// servers and create event listeners on separate threads 
/// that listen to server messages on SSE streams.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Connection points 
    const url = "http://localhost:3000";
    const event_url = url ++ "/events";
    const response_url = url ++ "/test";

    // Context can be a struct of anytype and is used to share state between 
    // event listeners, requests, and the rest of the application
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create new client object, responsible for listening to messages on server 
    // and sending requests 
    var client = ZigClient.init(allocator, &ctx);
    defer client.deinit();

    // Create new event listener object from client struct
    var listener = try client.newEventListener();

    // Adds event to be listend for
    try listener.newEvent(
        "data::connection_established", // Message eventListener thread is listening for 
        false, // Set's 'once' field to true, meaning it gets deleted once message is detected
        struct { //Call back function to be ran when the event is triggered 
           fn callback(event: *ZigClient.Event) !void {
                // Using mutex lock/unlock keeps the context data 'thread safe'. 
                // Make sure to use mutex if manipulating context data in event listeners
                event.ctx.mutex.lock();        
                defer event.ctx.mutex.unlock();
                event.ctx.ran_event_listener_callback = true;
           }
        }.callback,
    );

    // Start listening creates a sperate thread that will 
    // wait for event messages.  Stop listening on function end.
    try listener.startListening(event_url);
    defer listener.stopListening();

    const timeout = std.time.ns_per_s * 5;
    var timer = try std.time.Timer.start();

    // Here we repeatidly try to send request to server until
    // either success or timeout 
    timer.reset();

    while(true) {
        var response: ?ZigClient.Res  = client.get(response_url, .{}) catch null; 
        defer { if(response) |*res| res.deinit(); }

        if(response) |*res| {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();

            try ctx.copyVal("test_header", res.getHeader("Test-Header") orelse "Not Found");
            try ctx.copyVal("response_body", res.body);

            break;
        } 
        if(timer.read() >= timeout){
            std.debug.print("Did not get response from: {s}\n", .{response_url});
            return error.Timeout;
        }
    }

    std.debug.print(
        "\nCallback ran: {} \nHeader Value: {s} \nBody Value: {s}", 
        .{ctx.ran_event_listener_callback, ctx.test_header, ctx.response_body}
    );

    timer.reset();
    while(timer.read() <= timeout) { continue; }
}

// Context struct to help share state between event listeners and the rest of the program.
// While the Context can be anytype, it is highly reccomened that the Context struct contains 
// a std.Thread.Mutex object, and memory be tracked and managed appropriately. 

const Context = struct {
    // Add std.Thread.Mutex or use Atomic values in Context to
    // ensure thread saftey
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex = .{},
    ran_event_listener_callback: bool = false,

    test_header: []const u8 = "Not Found",
    response_body: []const u8 = "Not Found",

    fn init(allocator: std.mem.Allocator) @This() {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    fn copyVal(self: *@This(), comptime field_name: []const u8, val: anytype) !void {
        const field_ref = &@field(self, field_name);
        const FieldType = @TypeOf(field_ref.*);

        if(FieldType != @TypeOf(val)) { @compileError("Value of field does not match value of parameter\n"); }
        field_ref.* = try self.arena.allocator().dupe(std.meta.Child(FieldType), val);
    }
};
