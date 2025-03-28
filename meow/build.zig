const std = @import("std");

fn getFrontendSourceFileSubPathsRecursivly(b: *std.Build,frontendSourceFileSubPaths: *std.ArrayList([]u8),relativeSubPath: []const u8,firstRelativePathLength: ?u8) !void {
    const frontendSourceDirectory: std.fs.Dir = try std.fs.openDirAbsolute(
        std.Build.pathFromRoot(b,relativeSubPath),
        .{
            .iterate = true,
            .access_sub_paths = true
        }
    );

    var frontendSourceDirectoryIterator: std.fs.Dir.Iterator = frontendSourceDirectory.iterate();

    while (true) {
        const entry: ?std.fs.Dir.Entry = frontendSourceDirectoryIterator.next() catch null;
        
        if (entry) |unwrappedEntry| {
            const unwrappedEntryName: []u8 = try b.allocator.dupe(u8,std.mem.trimRight(u8,unwrappedEntry.name,".zig"));
            defer b.allocator.free(unwrappedEntryName);

            const relativeEntrySubPath: []u8 = try std.fs.path.join(b.allocator,&.{relativeSubPath,unwrappedEntryName});

            switch (unwrappedEntry.kind) {
                .file => {
                    try frontendSourceFileSubPaths.*.append(relativeEntrySubPath[(if (firstRelativePathLength) |unwrappedFirstRelativePathLength| unwrappedFirstRelativePathLength else relativeSubPath.len) + 1..]);
                },
                .directory => {
                    try getFrontendSourceFileSubPathsRecursivly(b,frontendSourceFileSubPaths,relativeEntrySubPath,if (firstRelativePathLength) |unwrappedFirstRelativePathLength| unwrappedFirstRelativePathLength else @truncate(relativeSubPath.len));
                },
                else => {}
            }
        } else {
            break;
        }
    }

    if (firstRelativePathLength) |_| {
        b.allocator.free(relativeSubPath);
    }
}

pub fn build(b: *std.Build) !void {
    const frontendSourceRelativePath: []const u8 = "src" ++ std.fs.path.sep_str ++ "frontend" ++ std.fs.path.sep_str ++ "src";

    var frontendSourceFileSubPaths: std.ArrayList([]u8) = std.ArrayList([]u8).init(b.allocator);
    defer frontendSourceFileSubPaths.deinit();

    try getFrontendSourceFileSubPathsRecursivly(b,&frontendSourceFileSubPaths,frontendSourceRelativePath,null);

    for (frontendSourceFileSubPaths.items) |frontendSourceFileSubPath| {
        const frontendSourceFileSubPathStem: []const u8 = std.fs.path.stem(frontendSourceFileSubPath);

        const relativeZigFilePath: []u8 = try std.fmt.allocPrint(b.allocator,"{s}" ++ std.fs.path.sep_str ++ "{s}.zig",.{frontendSourceRelativePath,frontendSourceFileSubPath});
        defer b.allocator.free(relativeZigFilePath);

        const executable: *std.Build.Step.Compile = b.addExecutable(.{
            .name = frontendSourceFileSubPathStem,
            .root_source_file = b.path(relativeZigFilePath),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding
            }),
            .optimize = .ReleaseSmall
        });



        const zjbDependency: *std.Build.Dependency = b.dependency("zjb",.{});
        
        executable.root_module.addImport("zjb",zjbDependency.module("zjb"));
        executable.entry = .disabled;
        executable.rdynamic = true;

        const zjbGenerateJs: *std.Build.Step.Run = b.addRunArtifact(zjbDependency.artifact("generate_js"));
        const zjbExtractOutputPath: std.Build.LazyPath = zjbGenerateJs.addOutputFileArg("zjb_extract.js");
        zjbGenerateJs.addArg("Zjb");
        zjbGenerateJs.addArtifactArg(executable);
        
        

        const binSubPath: []u8 = getBinSubPath: {
            const binSubPathBaseNameWithSeperator: []u8 = try std.mem.concat(b.allocator,u8,&.{std.fs.path.sep_str,std.fs.path.basename(frontendSourceFileSubPath)});
            defer b.allocator.free(binSubPathBaseNameWithSeperator);

            break :getBinSubPath if (std.mem.containsAtLeast(u8,frontendSourceFileSubPath,1,std.fs.path.sep_str)) try std.mem.replaceOwned(u8,b.allocator,frontendSourceFileSubPath,binSubPathBaseNameWithSeperator,"") else "";
        };
        defer b.allocator.free(binSubPath);
        
        const wasmFileName: []u8 = try std.fmt.allocPrint(b.allocator,"{s}.wasm",.{frontendSourceFileSubPathStem});
        defer b.allocator.free(wasmFileName);

        b.default_step.dependOn(&b.addInstallArtifact(executable,.{
            .dest_dir = std.Build.Step.InstallArtifact.Options.Dir {
                .override = std.Build.InstallDir.bin
            },
            .dest_sub_path = try std.fs.path.join(b.allocator,&.{binSubPath,wasmFileName})
        }).step);

        b.default_step.dependOn(&b.addInstallFileWithDir(
            zjbExtractOutputPath,
            std.Build.InstallDir.bin,
            try std.fs.path.join(b.allocator,&.{binSubPath,"zjb_extract.js"})
        ).step);

        b.default_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("src/frontend/webpages"),
            .install_dir = std.Build.InstallDir.bin,
            .install_subdir = ""
        }).step);
    }

    const executableTarget: std.Build.ResolvedTarget = b.standardTargetOptions(.{});
    
    const mainExecutable: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = executableTarget
        })
    });
    


    mainExecutable.root_module.addImport("httpZig",b.dependency("httpZig",.{}).module("httpz"));


    
    const mainExecutableRunArtifact: *std.Build.Step.Run = b.addRunArtifact(mainExecutable);
    mainExecutableRunArtifact.step.dependOn(b.getInstallStep());

    const runStep: *std.Build.Step = b.step("run","Run");
    runStep.dependOn(&mainExecutableRunArtifact.step);
}