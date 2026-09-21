const std = @import("std");
const simdjzon = @import("simdjzon");
const known_folders = @import("known-folders");

const dom = simdjzon.dom;

const base = "https://github.com/nankishr/tmpr/releases/download/Radio-Station-Data/";
const data_url = base ++ "stations.json.zst";
const hash_url = base ++ "stations.sha256";
const data_name = "stations.json";
const hash_name = "stations.sha256";
const ttl_ns: i96 = 6 * std.time.ns_per_hour;
const max_size = 50 * 1024 * 1024;

pub const Stations = struct {
    gpa: std.mem.Allocator,
    json: []u8,
    parser: dom.Parser,

    pub fn root(self: *Stations) dom.Element {
        return self.parser.element();
    }

    pub fn deinit(self: *Stations) void {
        self.parser.deinit();
        self.gpa.free(self.json);
        self.* = undefined;
    }
};

pub fn loadStations(init: std.process.Init) !Stations {
    const gpa = init.gpa;
    const io = init.io;

    var root = (try known_folders.open(io, gpa, init.environ_map, .cache, .{})) orelse
        return error.NoCacheDir;
    defer root.close(io);
    try root.createDirPath(io, "tmpr");
    var dir = try root.openDir(io, "tmpr", .{});
    defer dir.close(io);

    const local_hash: ?[]u8 = dir.readFileAlloc(io, hash_name, gpa, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (local_hash) |h| gpa.free(h);

    var json: ?[]u8 = dir.readFileAlloc(io, data_name, gpa, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (json) |d| gpa.free(d);

    const fresh = blk: {
        const st = dir.statFile(io, hash_name, .{}) catch break :blk false;
        const age = std.Io.Timestamp.now(io, .real).nanoseconds - st.mtime.nanoseconds;
        break :blk age >= 0 and age < ttl_ns;
    };

    if (!(fresh and local_hash != null and json != null)) {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        var hash_body: std.Io.Writer.Allocating = .init(gpa);
        defer hash_body.deinit();

        const remote_hash: ?[]const u8 = blk: {
            const res = client.fetch(.{
                .location = .{ .url = hash_url },
                .response_writer = &hash_body.writer,
            }) catch |err| {
                if (json == null) return err;
                std.log.warn("hash fetch failed ({t}); using stale cache", .{err});
                break :blk null;
            };
            if (res.status != .ok) {
                if (json == null) return error.BadStatus;
                std.log.warn("hash fetch returned {}; using stale cache", .{res.status});
                break :blk null;
            }
            var it = std.mem.tokenizeAny(u8, hash_body.written(), " \t\r\n");
            const tok = it.next() orelse return error.BadHashFile;
            if (tok.len != 64) return error.BadHashFile;
            break :blk tok;
        };

        if (remote_hash) |rh| {
            var unchanged = false;
            if (local_hash) |lh| {
                if (json != null) {
                    var lit = std.mem.tokenizeAny(u8, lh, " \t\r\n");
                    if (lit.next()) |lt| unchanged = std.ascii.eqlIgnoreCase(lt, rh);
                }
            }

            if (unchanged) {
                dir.writeFile(io, .{ .sub_path = hash_name, .data = rh }) catch |err|
                    std.log.warn("couldn't refresh cache timestamp: {t}", .{err});
                std.log.info("hash unchanged, using cache", .{});
            } else {
                std.log.info("downloading new stations", .{});

                if (json) |old| gpa.free(old);
                json = null;

                const new_json = blk: {
                    var body: std.Io.Writer.Allocating = .init(gpa);
                    defer body.deinit();
                    const res = try client.fetch(.{
                        .location = .{ .url = data_url },
                        .response_writer = &body.writer,
                    });
                    if (res.status != .ok) return error.BadStatus;

                    var zin: std.Io.Reader = .fixed(body.written());
                    var dec: std.compress.zstd.Decompress = .init(&zin, &.{}, .{});
                    var out: std.Io.Writer.Allocating = .init(gpa);
                    defer out.deinit();
                    _ = try dec.reader.streamRemaining(&out.writer);
                    break :blk try out.toOwnedSlice();
                };
                errdefer gpa.free(new_json);

                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(new_json, &digest, .{});
                const hex = std.fmt.bytesToHex(digest, .lower);
                if (!std.ascii.eqlIgnoreCase(&hex, rh)) return error.HashMismatch;

                try dir.writeFile(io, .{ .sub_path = data_name, .data = new_json });
                try dir.writeFile(io, .{ .sub_path = hash_name, .data = rh });

                json = new_json;
            }
        }
    }

    const bytes = json orelse return error.NoData;
    json = null;
    errdefer gpa.free(bytes);

    var parser = try dom.Parser.initFixedBuffer(gpa, bytes, .{});
    errdefer parser.deinit();
    try parser.parse();

    return .{ .gpa = gpa, .json = bytes, .parser = parser };
}

pub fn main(init: std.process.Init) !void {
    var stations = try loadStations(init);
    defer stations.deinit();

    std.log.info("parsed {d} bytes of json", .{stations.json.len});
}