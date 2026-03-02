# Zig HTTP Client Tool 
This tool allows for simple GET server request, as well as create sepearate threads for SSE EventListeners.  

## Setup
First, run this command in your project:
`zig fetch --save https://github.com/austinrtn/ZigClient/archive/refs/tags/v0.1.0.tar.gz`

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

