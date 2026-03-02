# Zig HTTP Client Tool 
This tool allows for simple GET server request, as well as create sepearate threads for SSE event listener.  

## Setup
First, run this command in your project:
```zig fetch --save https://github.com/austinrtn/ZigClient/archive/refs/tags/v0.1.0.tar.gz```

Next, copy and past this into your `build.zig` file: 
```zig 
const mod = b.addModule("ZigClient", .{
      .root_source_file = b.path("src/root.zig"),
      .target = target,
      .optimize = optimize,
});
```

Finally, add this to the top of your project file: 
```zig 
const Client = @import("ZigClient.zig");
const Context = struct {};
const ZigClient = Client.ZigClient(Context);
```

### Using the API 
Create a ZigClient using the ZigClient init function.  You'll need to create 
an instance of your Context struct: 
```zig
var ctx = Context{};
var client = ZigClient.init(allocator, &ctx);
defer client.deinit();
```

To create an SSE event listener, call ZigClient.NewEventListener and use the new listener to add events. 
The first parameter takes the message that you are listening to the server for, the second parameter 
is the function to be ran the onevent function, which is the function that will be called once the message is detected. 
The on event function requires an ZigClient.Event pointer.
```zig 
var listener = try client.newEventListener();

try listener.newEvent(
    "data::connection_established",
    struct {
        fn onevent(event: *ZigClient.Event) !void {
           _ = event; 
        }
    }
);
```

