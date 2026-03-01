const std = @import("std");
const Client = @import("ZigClient.zig");
const ZigClient = Client.ZigClient(Context);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const url = "http://localhost:3000";
    const event_url = url ++ "/events";
    const response_url = url ++ "/test";

    // Context can be a struct of anytype and is used to share state between 
    // event listeners, requests, and the rest of the application
    var ctx = Context{};

    // Create new client object, responsible for listening to messages on server 
    // and sending requests 
    var client = ZigClient.init(allocator, &ctx);
    defer client.deinit();

    // Create new event listener object from client struct
    var listener = try client.newEventListener();

    // Adds event to be listend for
    try listener.newEvent(
        "data::connection_established", // Message eventListener thread is listening for 
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

    // Here we wait until either the vent listener is triggered,
    // or until timeout
    while(true) {

        if(ctx.ran_event_listener_callback) {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.ran_event_listener_callback = true;
            break;
        }
        else if(timer.read() >= timeout) {
            std.debug.print("Event Listener did not recieve message\n", .{});
            return error.Timeout;
        }
    }

    // EventListener.stopListening closes the thread it's running on 
    // and can be called multiple times
    listener.stopListening();

    // Here we repeatidly try to send request to server until
    // either success or timeout 
    timer.reset();

    while(true) {
        const response: ?*ZigClient.Res  = client.get(response_url, .{}) catch null; 

        if(response) |res| {
            defer res.deinit();
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.response_file_name_header = res.headers.get("Test-Header") orelse "Not Found";
            ctx.response_body = res.body;
            break;
        } else if(timer.read() >= timeout){
            std.debug.print("Did not get response from: {s}\n", .{response_url});
            return error.Timeout;
        }
    }

    std.debug.print(
        "\nCallback ran: {} \nHeader Value: {s} \nBody Value: {s}", 
        .{ctx.ran_event_listener_callback, ctx.response_file_name_header, ctx.response_body}
    );

}

const Context = struct {
    // Add std.Thread.Mutex or use Atomic values in Context to 
    // ensure thread saftey
    mutex: std.Thread.Mutex = .{},
    ran_event_listener_callback: bool = false, 
                            
    response_file_name_header: []const u8 = "Not Found",
    response_body: []const u8 = "Not Found",
};
