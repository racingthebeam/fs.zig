import { MockFs } from "../mock-fs.js";
import { dumpFile, dumpFileToString, dumpFS } from "../dump.js";

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

// function assertNewEntryExists(assert, fs, parentPtr, name, entPtr) {
//     assert.ok(fs.exists(parentPtr, name), `${name} exists in the parent directory`);
//     const inodePtr = fs.lookup(parentPtr, name);
    

// function assertInodeIsDirectory(assert, fs, dirPtr) {
//     assert.ok(typeof dirPtr === 'number', "directory inode is a number");
//     assert.ok(fs.exists(0, 'test-dir'), "test-dir exists after creation");
//     assert.strictEqual(fs.lookup(0, 'test-dir'), dirPtr, "test-dir can be looked up in the root directory");
    
//     const stat = fs.stat(dirPtr);
//     assert.strictEqual(stat.inode, dirPtr, "test-dir's inode matches the looked up inode");
//     assert.strictEqual(stat.type, 2, "test-dir's stat type indicates directory");
//     assert.ok(stat.isDir, "test-dir is a directory");
//     assert.ok(!stat.isFile, "test-dir is not a file");
//     assert.ok(stat.mtime > 0, "test-dir has a valid mtime");
//     const stat = fs.stat(inodePtr);
//     if (stat.type !== 2) { // 2 indicates directory
//         throw new Error(`Inode ${inodePtr} is not a directory`);
//     }
// }

QUnit.module('mockfs', () => {
    QUnit.test('basic', (assert) => {
        const fs = makeFS();
        
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

    QUnit.test('file creation', (assert) => {
        const fs = makeFS();
        
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
    
    QUnit.test('open file operations', (assert) => {
        const fs = makeFS();

        const newFileInode = fs.create(0, 'test-file');

        const fh = fs.open(newFileInode, 0);
        fs.write(fh, stringBytes("Hello, World!"));
       
        assert.strictEqual(fs.stat(newFileInode).size, 13, "file size matches written data length");
        assert.strictEqual(dumpFileToString(fs, newFileInode), "Hello, World!", "file contents match written data");
        assert.strictEqual(fs.tell(fh), 13, "file tell position matches written data length");
        
        fs.seek(fh, 0);
        assert.strictEqual(fs.tell(fh), 0, "file tell position reset to 0 after seek"); 
        
        fs.write(fh, stringBytes("FNARR"));
        assert.strictEqual(fs.stat(newFileInode).size, 13, "file size matches written data length");
        assert.strictEqual(dumpFileToString(fs, newFileInode), "FNARR, World!", "file contents match written data");
        assert.strictEqual(fs.tell(fh), 5, "file tell position matches written data length");
        
        fs.seek(fh, 13);
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

    QUnit.module("directory operations", () => {
        QUnit.test("mkdir - creates directory", (assert) => {
            const fs = makeFS();
            
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

        QUnit.test("rmdir - removes directory", (assert) => {
            const fs = makeFS();
            
            fs.mkdir(0, 'test-dir');
            assert.ok(fs.exists(0, 'test-dir'), "test-dir exists before removal");
            
            fs.rmdir(0, 'test-dir');
            assert.notOk(fs.exists(0, 'test-dir'), "test-dir does not exist after removal");
            assert.throws(() => { fs.lookup(0, 'test-dir'); }, "lookup throws for removed directory");
            
            assert.deepEqual(dumpFS(fs), {});
        });

        QUnit.test("read directory entries", (assert) => {
            const fs = makeFS();
            
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

            assert.deepEqual(dumpFS(fs), {
                "dir-3": { type: 'dir', entries: {} },
                "dir-4": { type: 'dir', entries: {} },
                "dir-5": { type: 'dir', entries: {} },
                "dir-6": { type: 'dir', entries: {} }
            });
        });
    });
});
