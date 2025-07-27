import { MockFs } from "../mock-fs.js";
import { dumpFile, dumpFileToString, dumpFS } from "../dump.js";
import * as fs from "../bridge.js";
import { FileSystem } from "../fs.js";

function stringBytes(str) {
    return new TextEncoder().encode(str);
}

function makeFS() {
    return new MockFs();
}

// convert the given stat into a structure that's suitable for comparison
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
    testFS("zigfs", {
        create: function() {
            this.blockDeviceId = bridge.createBlockDevice(128, 512);
            const config = bridge.formatFS(this.blockDeviceId, 32);
            this.fileSystemId = bridge.initFS(this.blockDeviceId, config);
            this.fs = new FileSystem(bridge, this.fileSystemId);
        },
        destroy: function() {
            bridge.destroyFS(this.fileSystemId);
            bridge.destroyBlockDevice(this.blockDeviceId);
            delete this.fs;
            delete this.fileSystemId;
            delete this.blockDeviceId;
        }
    });

    testFS("mockfs", {
        create: function() {
            this.fs = new MockFs();
        },
        destroy: function() {}
    });
});

function testFS(moduleName, {create, destroy}) {
    QUnit.module(moduleName, function(hooks) {
        hooks.beforeEach(function() {
            create.call(this);
        });
        
        hooks.afterEach(function() {
            destroy.call(this);
        });

        runTests();
    });
}

function runTests() {
    QUnit.test('basic', function(assert) {
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

    QUnit.test('file creation', function(assert) {
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

    QUnit.module("directory operations", function() {
        QUnit.test("mkdir - creates directory", function(assert) {
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

        QUnit.test("rmdir - removes directory", function(assert) {
            const fs = this.fs;
            
            fs.mkdir(0, 'test-dir');
            assert.ok(fs.exists(0, 'test-dir'), "test-dir exists before removal");
            
            fs.rmdir(0, 'test-dir');
            assert.notOk(fs.exists(0, 'test-dir'), "test-dir does not exist after removal");
            assert.throws(() => { fs.lookup(0, 'test-dir'); }, "lookup throws for removed directory");
            
            assert.deepEqual(dumpFS(fs), {});
        });

        QUnit.test("read directory entries", function(assert) {
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
