import { MockFs } from "../mock-fs.js";
import { dumpFile, dumpFileToString, dumpFS } from "../dump.js";
import * as fs from "../bridge.js";
import { FileSystem } from "../fs.js";

function stringBytes(str) {
    return new TextEncoder().encode(str);
}

const BlockSize = 128;
const BlockCount = 4096;
const DiskSize = BlockSize * BlockCount;
const DirEntSize = 16;
const DirEntsPerBlock = BlockSize / DirEntSize;
const BlockPointersPerBlock = BlockSize / 2;
const IndirectThreshold = (BlockPointersPerBlock / 2) * BlockSize;
const MaxFileSize = IndirectThreshold + ((BlockPointersPerBlock / 2) * BlockPointersPerBlock * BlockSize) - 1;

console.log("IndirectThreshold", IndirectThreshold);
console.log("MaxFileSize", MaxFileSize);
console.log("DiskSize", DiskSize);

// convert the given Stat into a structure that's suitable for comparison
// across different filesystem implementations. in particular, we ignore
// the inode pointer (since this is an internal implementation detail),
// and force size to 0 for directories, since they don't have a size in the
// same way files do. mtime is also dropped, since we don't care about the
// actual time in tests. the resulting structure is suitable for deep
// comparison in tests.
function portableStat(stat) {
    return {
        name: stat.name,
        type: (stat.isDir ? 'dir' : 'file'),
        executable: stat.isExecutable,
        size: stat.isDir ? 0 : stat.size
    };
}

fs.load("../../build/fs.wasm").then((bridge) => {
    console.log("WASM module loaded");

    testFS("zigfs", {
        mock: false,
        create: function () {
            this.blockDeviceId = bridge.createBlockDevice(BlockSize, BlockCount);
            const config = bridge.formatFS(this.blockDeviceId, 32);
            this.fileSystemId = bridge.initFS(this.blockDeviceId, config);
            this.fs = new FileSystem(bridge, this.fileSystemId);
        },
        destroy: function () {
            bridge.destroyFS(this.fileSystemId);
            bridge.destroyBlockDevice(this.blockDeviceId);
            delete this.fs;
            delete this.fileSystemId;
            delete this.blockDeviceId;
        }
    });

    testFS("mockfs", {
        mock: true,
        create: function () {
            this.fs = new MockFs();
        },
        destroy: function () {
            delete this.fs;
        }
    });

    QUnit.start();
});

function testFS(moduleName, { create, destroy, mock }) {
    QUnit.module(moduleName, function (hooks) {
        hooks.beforeEach(function () {
            create.call(this);
        });

        hooks.afterEach(function () {
            destroy.call(this);
        });

        runTests();
        if (!mock) {
            runZigTests();
        }
    });
}

function runTests() {
    QUnit.test("...", function (assert) {
        assert.ok(true);
    });

    //
    // Lookup

    QUnit.test("lookup (when no file)", function (assert) {
        assert.throws(() => { this.fs.lookup(0, 'file'); });
    });

    QUnit.test("lookup (when directory)", function (assert) {
        const inode = this.fs.mkdir(0, 'dir');
        assert.strictEqual(this.fs.lookup(0, 'dir'), inode, "lookup returns inode of existing directory");
    });

    QUnit.test("lookup (when file)", function (assert) {
        const inode = this.fs.create(0, 'file');
        assert.strictEqual(this.fs.lookup(0, 'file'), inode, "lookup returns inode of existing file");
    });

    //
    // Exists

    QUnit.test("exists (when no file)", function (assert) {
        assert.notOk(this.fs.exists(0, 'file'));
    });

    QUnit.test("exists (when directory)", function (assert) {
        this.fs.mkdir(0, 'dir');
        assert.ok(this.fs.exists(0, 'dir'));
    });

    QUnit.test("exists (when file)", function (assert) {
        this.fs.create(0, 'file');
        assert.ok(this.fs.exists(0, 'file'));
    });

    //
    // Stat (basic)

    QUnit.test("stat (root dir)", function (assert) {
        const stat = this.fs.stat(0);
        assert.strictEqual(stat.name, null);
        assert.strictEqual(stat.inode, 0);
        assert.ok(stat.isDir);
        assert.ok(!stat.isFile);
        assert.ok(!stat.isExecutable);
        assert.ok(stat.mtime > 0);
    });

    QUnit.test("stat (file)", function (assert) {
        const inode = this.fs.create(0, "test");
        const stat = this.fs.stat(inode);
        assert.strictEqual(stat.name, null);
        assert.strictEqual(stat.inode, inode);
        assert.ok(!stat.isDir);
        assert.ok(stat.isFile);
        assert.ok(!stat.isExecutable);
        assert.ok(stat.mtime > 0);
    });

    QUnit.test("stat (dir)", function (assert) {
        const inode = this.fs.mkdir(0, "test");
        const stat = this.fs.stat(inode);
        assert.strictEqual(stat.name, null);
        assert.strictEqual(stat.inode, inode);
        assert.ok(stat.isDir);
        assert.ok(!stat.isFile);
        assert.ok(!stat.isExecutable);
        assert.ok(stat.mtime > 0);
    });

    //
    // Open file

    QUnit.test('open file operations', function (assert) {
        const fs = this.fs;

        const newFileInode = fs.create(0, 'test-file');

        const fh = fs.open(newFileInode, 0);
        fs.write(fh, stringBytes("Hello, World!"));

        assert.strictEqual(fs.stat(newFileInode).size, 13, "file size matches written data length");
        assert.strictEqual(dumpFileToString(fs, newFileInode), "Hello, World!", "file contents match written data");
        assert.strictEqual(fs.tell(fh), 13, "file tell position matches written data length");

        fs.seek(fh, 0, 0);
        assert.strictEqual(fs.tell(fh), 0, "file tell position reset to 0 after seek");

        fs.write(fh, stringBytes("FNARR"));
        assert.strictEqual(fs.stat(newFileInode).size, 13, "file size matches written data length");
        assert.strictEqual(dumpFileToString(fs, newFileInode), "FNARR, World!", "file contents match written data");
        assert.strictEqual(fs.tell(fh), 5, "file tell position matches written data length");

        fs.seek(fh, 13, 0);
        fs.write(fh, stringBytes(" This is goodbye :("));
        assert.strictEqual(fs.stat(newFileInode).size, 32, "file size updates after append");
        assert.strictEqual(dumpFileToString(fs, newFileInode), "FNARR, World! This is goodbye :(", "file contents match written data after append");
        assert.strictEqual(fs.tell(fh), 32, "file tell position matches new size after append");

        fs.write(fh, stringBytes("..."));
        assert.strictEqual(fs.stat(newFileInode).size, 35);
        assert.strictEqual(dumpFileToString(fs, newFileInode), "FNARR, World! This is goodbye :(...");
        assert.strictEqual(fs.tell(fh), 35);

        //
        // Second open handle to same file

        const fh2 = fs.open(newFileInode, 0);
        const buf = new Uint8Array(8);

        // Chunked reads

        assert.strictEqual(fs.read(buf, fh2), 8, "read returns correct number of bytes");
        assert.strictEqual(new TextDecoder().decode(buf), "FNARR, W");
        assert.ok(!fs.eof(fh2));

        assert.strictEqual(fs.read(buf, fh2), 8, "read returns correct number of bytes");
        assert.strictEqual(new TextDecoder().decode(buf), "orld! Th");
        assert.ok(!fs.eof(fh2));

        assert.strictEqual(fs.read(buf, fh2), 8, "read returns correct number of bytes");
        assert.strictEqual(new TextDecoder().decode(buf), "is is go");
        assert.ok(!fs.eof(fh2));

        assert.strictEqual(fs.read(buf, fh2), 8, "read returns correct number of bytes");
        assert.strictEqual(new TextDecoder().decode(buf), "odbye :(");
        assert.ok(!fs.eof(fh2));

        assert.strictEqual(fs.read(buf, fh2), 3, "read returns correct number of bytes");
        assert.strictEqual(new TextDecoder().decode(buf.subarray(0, 3)), "...");
        assert.ok(fs.eof(fh2));

        assert.strictEqual(fs.read(buf, fh2), 0, "read returns 0 bytes at EOF");

        assert.deepEqual(dumpFS(fs), {
            "test-file": {
                type: 'file',
                contents: stringBytes("FNARR, World! This is goodbye :(..."),
                executable: false
            }
        });
    });

    // perform a fuzz test with 10 simultaneous writers, 255 passes, 100-5000 ops per pass
    QUnit.test('read/write fuzz', function (assert) {
        let totalBytesWritten = 0;
        const start = Date.now();

        // 255 seems to be maximum number of assertions QUint allows
        for (let pass = 0; pass < 255; pass++) {
            const fileContents = new Uint8Array(MaxFileSize);
            let fileSize = 0;

            const filename = `file${pass}`;
            const inode = this.fs.create(0, filename);

            // create a pool of 10 writers (real and simulated)
            const writers = [];
            for (let i = 0; i < 10; i++) {
                writers.push({ offset: 0, fd: this.fs.open(inode) });
            }

            const ops = 100 + Math.floor(Math.random() * 4900);
            for (let i = 0; i < ops; i++) {
                // pick a writer
                const w = writers[Math.floor(Math.random() * writers.length)];

                // seek to a new point in the file sometimes
                const p = Math.random();
                if (p < 0.05) { // seek to end
                    w.offset = fileSize;
                    this.fs.seek(w.fd, fileSize, 0);
                } else if (p < 0.2) { // seek to random offset
                    const newOffset = Math.floor(Math.random() * fileSize);
                    w.offset = newOffset;
                    this.fs.seek(w.fd, newOffset, 0);
                }

                const bytesToWrite = Math.min(
                    Math.floor(Math.random() * 512),
                    fileContents.length - w.offset
                );

                const chunk = new Uint8Array(bytesToWrite);
                chunk.fill(i % 256);

                // write to the real file
                this.fs.write(w.fd, chunk);

                // write to the mock file
                fileContents.subarray(w.offset, w.offset + bytesToWrite).set(chunk);
                w.offset += bytesToWrite;
                if (w.offset > fileSize) {
                    fileSize = w.offset;
                }

                totalBytesWritten += bytesToWrite;
            }

            // close the writers
            for (const w of writers) {
                this.fs.close(w.fd);
            }

            // read back the full file from the filesystem
            const actual = dumpFile(this.fs, inode);

            // delete the filename
            this.fs.unlink(0, filename);

            assert.deepEqual(actual, fileContents.subarray(0, fileSize), `pass ${pass} (ops=${ops}, size=${fileSize})`);
        }

        console.log(`wrote ${totalBytesWritten / 1048576}MiB in ${(Date.now() - start) / 1000}s`);
    });

    QUnit.test('basic', function (assert) {
        const fs = this.fs;

        assert.notOk(fs.exists(0, 'foo'), "foo does not exist in the root directory");
        assert.throws(() => { fs.lookup(0, 'foo'); }, "lookup throws for non-existent file");

        fs.mkdir(0, 'foo');
        assert.ok(fs.exists(0, 'foo'), "after creation, foo exists in the root directory");

        const fooInode = fs.lookup(0, 'foo');
        assert.ok(typeof fooInode === 'number', "foo can be looked up in the root directory");

        const stat = fs.stat(fooInode);
        assert.strictEqual(stat.inode, fooInode, "foo's inode matches the looked up inode");
        assert.strictEqual(stat.type, 2, "foo's stat type indicates directory");
        assert.ok(stat.isDir, "foo is a directory");
        assert.ok(!stat.isFile, "foo is not a file");
        assert.ok(stat.mtime > 0, "foo has a valid mtime");

        fs.rmdir(0, 'foo');

        assert.notOk(fs.exists(0, 'foo'), "after deletion, foo does not exist in the root directory");
        assert.throws(() => { fs.lookup(0, 'foo'); });
    });

    QUnit.test('file creation', function (assert) {
        const fs = this.fs;

        const newFileInode = fs.create(0, 'test-file');
        assert.ok(typeof newFileInode === 'number', "new file inode is a number");
        assert.ok(fs.exists(0, 'test-file'), "new file exists in the root directory");
        assert.strictEqual(fs.lookup(0, 'test-file'), newFileInode, "new file can be looked up in the root directory");

        const stat = fs.stat(newFileInode);
        assert.strictEqual(stat.inode, newFileInode, "new file's inode matches the looked up inode");
        assert.strictEqual(stat.type, 1, "new files's stat type indicates file");
        assert.ok(!stat.isDir, "new file is not a directory");
        assert.ok(stat.isFile, "foo file is a file");
        assert.ok(stat.mtime > 0, "foo has a valid mtime");
    });

    QUnit.module("directory operations", function () {
        QUnit.test("mkdir - creates directory", function (assert) {
            const fs = this.fs;

            const dirPtr = fs.mkdir(0, 'test-dir');
            assert.ok(typeof dirPtr === 'number', "directory inode is a number");
            assert.ok(fs.exists(0, 'test-dir'), "test-dir exists after creation");
            assert.strictEqual(fs.lookup(0, 'test-dir'), dirPtr, "test-dir can be looked up in the root directory");

            const stat = fs.stat(dirPtr);
            assert.strictEqual(stat.inode, dirPtr, "test-dir's inode matches the looked up inode");
            assert.strictEqual(stat.type, 2, "test-dir's stat type indicates directory");
            assert.ok(stat.isDir, "test-dir is a directory");
            assert.ok(!stat.isFile, "test-dir is not a file");
            assert.ok(stat.mtime > 0, "test-dir has a valid mtime");

            assert.deepEqual(dumpFS(fs), {
                "test-dir": {
                    type: 'dir',
                    entries: {}
                }
            });
        });

        QUnit.test("rmdir - removes directory", function (assert) {
            const fs = this.fs;

            fs.mkdir(0, 'test-dir');
            assert.ok(fs.exists(0, 'test-dir'), "test-dir exists before removal");

            fs.rmdir(0, 'test-dir');
            assert.notOk(fs.exists(0, 'test-dir'), "test-dir does not exist after removal");
            assert.throws(() => { fs.lookup(0, 'test-dir'); }, "lookup throws for removed directory");

            assert.deepEqual(dumpFS(fs), {});
        });

        QUnit.test("read directory entries", function (assert) {
            const fs = this.fs;

            fs.mkdir(0, 'dir-1'); // removed
            fs.mkdir(0, 'dir-2'); // removed
            fs.mkdir(0, 'dir-3');
            fs.rmdir(0, 'dir-2');
            fs.mkdir(0, 'dir-4');
            fs.mkdir(0, 'dir-5');
            fs.rmdir(0, 'dir-1');
            fs.mkdir(0, 'dir-6');

            const dh = fs.opendir(0);

            const entries = {};
            while (true) {
                const entry = fs.readdir(dh);
                if (!entry) break;
                entries[entry.name] = portableStat(entry);
            }

            fs.closedir(dh);

            assert.deepEqual(entries, {
                "dir-3": { name: "dir-3", type: 'dir', executable: false, size: 0 },
                "dir-4": { name: "dir-4", type: 'dir', executable: false, size: 0 },
                "dir-5": { name: "dir-5", type: 'dir', executable: false, size: 0 },
                "dir-6": { name: "dir-6", type: 'dir', executable: false, size: 0 }
            });
        });
    });
}

// tests that only apply to the real filesystem implementation
function runZigTests() {
    QUnit.test("write file of maximum size", function (assert) {
        const inode = this.fs.create("test");

        const fh = this.fs.open(inode, 0);

        const buffer = new Uint8Array(64);
        for (let i = 0; i < buffer.length; i++) {
            buffer[i] = i;
        }

        // fill up the file, right to the end
        let totalWritten = 0;
        while (totalWritten < MaxFileSize) {
            const bytesToWrite = Math.min(MaxFileSize - totalWritten, buffer.length);
            const written = this.fs.write(fh, buffer.subarray(0, bytesToWrite));
            assert.strictEqual(written, bytesToWrite, `wrote ${buffer.length} bytes at offset ${totalWritten}`);
            totalWritten += written;
        }

        // writing one more byte should fail
        assert.throws(() => {
            this.fs.write(fh, buffer.subarray(0, 1));
        });

        this.fs.close(fh);
    });
}
