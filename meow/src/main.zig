const std = @import("std");
const httpZig = @import("httpZig");

fn routerCallback(request: *httpZig.Request,response: *httpZig.Response) !void {
    const projectCurrentWorkingDirectory: []u8 = try std.process.getCwdAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(projectCurrentWorkingDirectory);
    
    const projectOutBinDirectoryAbsolutePath: []const u8 = try std.fs.path.join(std.heap.page_allocator,&.{projectCurrentWorkingDirectory,"zig-out" ++ std.fs.path.sep_str ++ "bin"});
    defer std.heap.page_allocator.free(projectOutBinDirectoryAbsolutePath);

    const parsedRequestUrl: []u8 = try std.heap.page_allocator.dupe(u8,request.url.path);
    defer std.heap.page_allocator.free(parsedRequestUrl);
    _ = std.mem.replace(u8,parsedRequestUrl,"/",std.fs.path.sep_str,parsedRequestUrl);

    var requestUrlPathIsDynamic: bool = false;

    var dynamicRequestUrlPathVariables = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer dynamicRequestUrlPathVariables.deinit();

    var requestFilePathIterator = std.mem.splitAny(u8,parsedRequestUrl,std.fs.path.sep_str);
    _ = requestFilePathIterator.next();

    var requestFilePathSegments = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer requestFilePathSegments.deinit();

    std.debug.print("Request url path: {s}\n",.{parsedRequestUrl});

    while (true) {
        const requestUrlPathSegment: ?[]const u8 = requestFilePathIterator.next();

        if (requestUrlPathSegment != null) {
            std.debug.print("Current path segment: {s}\n",.{requestUrlPathSegment.?});

            const joinedRequestFilePathSegments: []const u8 = try std.mem.join(std.heap.page_allocator,std.fs.path.sep_str,requestFilePathSegments.items);
            defer std.heap.page_allocator.free(joinedRequestFilePathSegments);

            const fileDirectoryPath: []const u8 = try std.fs.path.join(std.heap.page_allocator,&.{projectOutBinDirectoryAbsolutePath,joinedRequestFilePathSegments});
            defer std.heap.page_allocator.free(fileDirectoryPath);

            const fileDirectory: ?std.fs.Dir = std.fs.openDirAbsolute(fileDirectoryPath,.{.iterate = true}) catch null;
            var pathSegmentToAppend: []const u8 = requestUrlPathSegment.?;

            if (fileDirectory != null) {
                var fileDirectoryIterator: std.fs.Dir.Iterator = fileDirectory.?.iterate();
                var dynamicPathSegment: ?[]const u8 = null;
                var pathSegmentIsStatic: bool = false;

                {
                    while (true) {
                        const fileDirectoryEntry: ?std.fs.Dir.Entry = try fileDirectoryIterator.next();

                        if (fileDirectoryEntry != null) {
                            if (std.mem.eql(u8,requestUrlPathSegment.?,fileDirectoryEntry.?.name)) {
                                pathSegmentIsStatic = true;
                            }
                            
                            if (std.mem.eql(u8,requestUrlPathSegment.?,std.fs.path.stem(fileDirectoryEntry.?.name))) {
                                pathSegmentIsStatic = true;
                            }
                        } else {
                            break;
                        }
                    }

                    if (!pathSegmentIsStatic) {
                        fileDirectoryIterator.reset();
                        
                        while (true) {
                            const fileDirectoryEntry: ?std.fs.Dir.Entry = try fileDirectoryIterator.next();

                            if (fileDirectoryEntry != null) {
                                if (std.mem.startsWith(u8,fileDirectoryEntry.?.name,"[") and (std.mem.endsWith(u8,fileDirectoryEntry.?.name,"]") or std.mem.endsWith(u8,fileDirectoryEntry.?.name,"].html"))) {
                                    dynamicPathSegment = try std.heap.page_allocator.dupe(u8,fileDirectoryEntry.?.name);

                                    std.debug.print("Found dynamic variable: {s}\n",.{fileDirectoryEntry.?.name});
                                    
                                    if (dynamicPathSegment != null) {
                                        try dynamicRequestUrlPathVariables.append(requestUrlPathSegment.?);
                                    }

                                    requestUrlPathIsDynamic = true;
                                    continue;
                                }
                            } else {
                                break;
                            }
                        }
                    }
                }

                if (!pathSegmentIsStatic and dynamicPathSegment != null) {
                    pathSegmentToAppend = dynamicPathSegment.?;
                }
            }

            try requestFilePathSegments.append(pathSegmentToAppend);

            std.debug.print("Appended path segment: {s}\n",.{pathSegmentToAppend});
        } else {
            break;
        }
    }

    const requestFilePath: []const u8 = try std.mem.join(std.heap.page_allocator,std.fs.path.sep_str,requestFilePathSegments.items);
    defer std.heap.page_allocator.free(requestFilePath);

    std.debug.print("Request file path: {s}\n", .{requestFilePath});

    const fileExtention: []const u8 = std.fs.path.extension(requestFilePath);

    var file: ?std.fs.File = null;
    
    {
        const fileAbsolutePath: []u8 = try std.fs.path.join(std.heap.page_allocator,&.{projectOutBinDirectoryAbsolutePath,requestFilePath});
        defer std.heap.page_allocator.free(fileAbsolutePath);

        const fileAbsolutePath1: []u8 = try std.mem.join(std.heap.page_allocator,"",&.{fileAbsolutePath,".html"});
        defer std.heap.page_allocator.free(fileAbsolutePath1);

        var paths = std.ArrayList([]const u8).init(std.heap.page_allocator);
        defer paths.deinit();

        try paths.appendSlice(&.{fileAbsolutePath,fileAbsolutePath1});

        var fileAbsolutePath2: ?[]u8 = null;

        defer {
            if (fileAbsolutePath2 != null) {
                std.heap.page_allocator.free(fileAbsolutePath2.?);
            }
        }

        if (std.mem.eql(u8,parsedRequestUrl,std.fs.path.sep_str)) {
            fileAbsolutePath2 = try std.fs.path.join(std.heap.page_allocator,&.{fileAbsolutePath,"main.html"});
            try paths.append(fileAbsolutePath2.?);
        }

        var filePath: ?[]const u8 = null;

        for (paths.items) |path| {
            const potentialFile: ?std.fs.File = std.fs.openFileAbsolute(path,.{.mode = .read_only}) catch null;
            
            if (potentialFile != null) {
                defer potentialFile.?.close();

                const metadata: ?std.fs.File.Metadata = potentialFile.?.metadata() catch null;

                if (metadata != null) {
                    if (metadata.?.kind() == .file) {
                        std.debug.print("File path (final): {s}\n",.{path});
                        filePath = path;
                        break;
                    }
                }
            }
        }

        if (filePath != null) {
            file = try std.fs.openFileAbsolute(filePath.?,.{.mode = .read_only});
        }
    }

    if (file != null) {
        defer file.?.close();

        const fileMimeType: []const u8 = getFileMimeType: {
            if (std.mem.endsWith(u8,fileExtention,".html")) {
                break :getFileMimeType "text/html";
            } else if (std.mem.endsWith(u8,fileExtention,".css")) {
                break :getFileMimeType "text/css";
            } else if (std.mem.endsWith(u8,fileExtention,".wasm")) {
                break :getFileMimeType "application/wasm";
            } else if (std.mem.endsWith(u8,fileExtention,".js")) {
                break :getFileMimeType "application/javascript";
            } else if (std.mem.endsWith(u8,fileExtention,".json")) {
                break :getFileMimeType "application/json";
            } else if (std.mem.endsWith(u8,fileExtention,".png")) {
                break :getFileMimeType "image/png";
            } else if (std.mem.endsWith(u8,fileExtention,".jpg") or std.mem.endsWith(u8,fileExtention,".jpeg")) {
                break :getFileMimeType "image/jpeg";
            } else if (std.mem.endsWith(u8,fileExtention,".gif")) {
                break :getFileMimeType "image/gif";
            } else {
                break :getFileMimeType "text/html";
            }
        };

        response.headers.add("Content-Type",fileMimeType);

        var fileContents: []u8 = try file.?.reader().readAllAlloc(std.heap.page_allocator,std.math.maxInt(usize));
        defer std.heap.page_allocator.free(fileContents);

        std.debug.print("Path is dynamic: {any}\n",.{requestUrlPathIsDynamic});

        const injectDynamicRequestPathVariables: bool = requestUrlPathIsDynamic and (std.mem.eql(u8,fileExtention,".html") or std.mem.eql(u8,fileExtention,""));

        if (injectDynamicRequestPathVariables) {
            var dynamicRequestUrlPathVariablesJsonString = std.ArrayList(u8).init(std.heap.page_allocator);
            defer dynamicRequestUrlPathVariablesJsonString.deinit();

            try std.json.stringify(dynamicRequestUrlPathVariables.items,.{},dynamicRequestUrlPathVariablesJsonString.writer());

            const replacedDynamicPathVariable: []u8 = try std.fmt.allocPrint(std.heap.page_allocator,"const dynamicPathVariables = {s};",.{dynamicRequestUrlPathVariablesJsonString.items});
            defer std.heap.page_allocator.free(replacedDynamicPathVariable);

            std.debug.print("Injected json variable: {s}\n",.{replacedDynamicPathVariable});

            const fileContentsDuplicate: []const u8 = try std.heap.page_allocator.dupe(u8,fileContents);
            defer std.heap.page_allocator.free(fileContentsDuplicate);

            std.heap.page_allocator.free(fileContents);

            fileContents = try std.mem.replaceOwned( 
                u8,
                std.heap.page_allocator,
                fileContentsDuplicate,
                "const dynamicPathVariables = [];",
                replacedDynamicPathVariable
            );
        }
        
        _ = try response.writer().write(fileContents);
    } else {
        try response.writer().print("File doesn't exist D:\n",.{});
    }

    std.debug.print("Resource existed: {any}\n\n",.{file != null});
}

pub fn main() !void {
    var server = try httpZig.Server(void).init(std.heap.page_allocator,.{
        .address = "0.0.0.0",
        .port = 1080
    },{});

    defer {
        server.stop();
        server.deinit();
    }
    
    (try server.router(.{})).all("*",routerCallback,.{});
    
    try server.listen();
}