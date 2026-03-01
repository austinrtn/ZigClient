const std = @import("std");
const Client = @import("HttpClient");
const HttpClient = Client.HttpClient(Context);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const url = "http://localhost:3000";
    const event_url = url ++ "/events";
    const response_url = url ++ "/test";

    // Contexxt can be a struct of anytype and is used to share state between 
    // event listeners, requests, and the rest of the application
    var ctx = Context{};

    // Create new client object, responsible for listening to messages on server 
    // and sending requests 
    var client = HttpClient.init(allocator, &ctx);
    defer client.deinit();

    var listener = try client.newEventListener();

    listener.newEvent(
        "data::connection_established", 
        struct {
           fn callback(event: *Client.EventListener) !void {
                _ = event;
           }
        }.callback(),
        );

    // Start listening creates a sperate thread that will 
    // wait for event messages 
    listener.startListening(event_url);
    defer listener.stopListening();
}

const Context = struct {
    // Using lock/unlock keeps the context data 'thread safe'. 
    // Make sure to use mutex if manipulating context data in event listeners
    mutext: std.Thread.Mutex = .{},
    listening: bool = false, // Dummy var 
    req_text: ?[]const u8 = null,
};
