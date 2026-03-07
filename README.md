# Zig HTTP Client Tool 
This tool allows for simple GET server request, as well as create sepearate threads for SSE event listener.  

# Setup
First, run this command in your project:
```zig fetch --save https://github.com/austinrtn/ZigClient/archive/refs/tags/v0.1.0.tar.gz```

Next, copy and past this into your `build.zig` file: 
```zig 
  const zigclient_dep = b.dependency("ZigClient", .{
      .target = target,
      .optimize = optimize,
  });
  const zigclient_mod = zigclient_dep.module("ZigClient");

  // then when creating your exe/module:
  exe.root_module.addImport("ZigClient", zigclient_mod);
```

Finally, add this to the top of your project file: 
```zig 
const Client = @import("ZigClient");
const Context = struct {}; // Leave struct empty if no context
const ZigClient = Client.ZigClient(Context);
```

# Getting Started
Create a ZigClient using the ZigClient init function.  You'll need to create 
an instance of your Context struct: 
```zig
var ctx = Context{};
var client = ZigClient.init(allocator, &ctx);
defer client.deinit();
```

## GET Reqeust
To send a get request, use the ZigClient.get function which returns both the response status, headers and body.
```zig
var response: ZigClient.Res = try client.get(response_url, .{});
```

To get specific headers, you can either use the Response.getHeader method, or you can loop through the headers slice.  
It should be noted that the getHeader function returns only one header value, and that headers are case sensitive.
The method return null if no header is found.
```zig
const header_val = response.getHeader("Test-header") orelse error.NoHeader;
// Or to itterate headers 
for(response.headers) |header| {
    if(std.mem.eql(u8, header.name, "Test-Header")) {
        std.debug.print("{s}\n", .{header.value})
    }
}
```
## SSE Event Listener
To create an SSE event listener, call ZigClient.NewEventListener and use the new listener to add events. 
The first parameter takes the message that you are listening to the server for, the second parameter determines wether the 
message will be a one-time event and will not be triggered more than once (true), or wheteher it will persist after being triggered false.  The third parameter
is the function to be ran the onevent function, which is the function that will be called once the message is detected.
The on event function requires an ZigClient.Event pointer.
```zig 
var listener = try client.newEventListener();

try listener.newEvent(
    "data::connection_established",
    true,
    struct {
        fn onevent(event: *ZigClient.Event) !void { // Must contain event parameter and return error-void union
           _ = event; 
        }
    }
);

// Creates a sepearate thread where messages are listened for 
try listener.startListening();
defer listener.stopListening(); // Joins thread and ends listening.  If missing, will cause runtim panic in debug mode
```

To *reset* a one time event so that it can be triggered again, you can use `listener.resetEvent` and pass the message of the event you are looking to reset, or 
you can call `listener.resetAllEvents` to reset all events.

```zig
listener.resetEvent("data::connection_established");
```

# Context Struct 
The Context struct is stored in the client as the 'ctx' variable and is completely user defined.  
This variable is intended to allow the user to pass state from the main program to the event listner thread(s) and back again.  
While the ctx variable is accessable throught the event pointer in the onevent function, it is not inherently thread-safe and 
requires either a Mutex field, or fields that get manipulated across threads should be atomic.  Memory saved to the variable 
will also need to be manually managed.

```zig
/// Example of context struct with memory / thread safe usage
//
const Context = struct {
    arena: std.heap.ArenaAllocator, 
    mutex: std.Thread.Mutex = .{},
    bar: []const u8 = "",

    fn init(gpa: std.mem.Allocator) @This() {
        return .{.arena = std.heap.ArenaAllocator.init(allocator)}; 
    }

    fn deinit(self: *@This()) {
        self.arean.allocator().deinit();
    }
};

// Initializing context for main clinet instance
var ctx = Context{};
defer ctx.deinit();

var client = ZigClient.init(allocator, &ctx);
defer client.deinit(); 

// Durring onevent EventListener function 
fn foo(event: *ZigClient.Event) !void {
    // Prevent multithread race conditions
    event.ctx.mutex.lock();
    defer event.mutex.unlock;

    event.ctx.bar = try event.ctx.allocator.dupe(u8, "Hello World");
}
```
