import Darwin
import Foundation

// The kind of a directory entry as reported by either enumeration path.
// Symlinks and special files (fifo/char/block/socket) are surfaced so the
// caller can apply the "skip entirely" rule (see FileScanner.swift semantics);
// this module never resolves symlink targets.
enum BulkEntryKind: Sendable {
    case directory
    case file
    case symlink
    case other
}

// One immediate child of a directory, with just enough metadata for the
// scanner to apply its rules (mount-point / hardlink / dedup checks) without
// an additional per-entry stat call. `dev`/`ino`/`linkCount`/`allocatedSize`
// are meaningful for `.directory` (dev, ino only) and `.file` (all four);
// they are zero for `.symlink`/`.other`, which the scanner always skips.
struct BulkDirEntry: Sendable {
    let name: String
    let kind: BulkEntryKind
    let dev: UInt64
    let ino: UInt64
    let linkCount: UInt32
    let allocatedSize: Int64
}

// Thrown when `getattrlistbulk` can't be used for a directory at all (the
// filesystem doesn't support it) or when the packed attribute buffer can't be
// parsed with confidence (unexpected layout, truncated entry, non-UTF8 name).
// Callers should retry the same directory with `fallbackEnumerateDirectory(fd:)`.
struct BulkEnumerationUnavailable: Error {}

private let bulkBufferCapacity = 64 * 1_024
private let unsupportedBulkErrors: Set<Int32> = [EINVAL, ENOTSUP, ENOSYS]

// Only the attributes FileScanner actually needs: identity (dev/ino via
// DEVID+FILEID), name, and object type for every entry, plus link count and
// allocated size for regular files. Keeping the request minimal keeps the
// packed buffer layout small and simple to parse.
private var requestedAttrList: attrlist {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_FILEID)
    list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    return list
}

private let requiredCommonAttrs = attrgroup_t(ATTR_CMN_NAME)
    | attrgroup_t(ATTR_CMN_OBJTYPE)
    | attrgroup_t(ATTR_CMN_DEVID)
    | attrgroup_t(ATTR_CMN_FILEID)
private let requiredFileAttrs = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

// Enumerates the immediate children of an already-open directory descriptor
// via getattrlistbulk(2): one syscall per ~64 KB batch returns name + metadata
// together for every entry in the batch, instead of one syscall per entry
// (readdir) plus one more (fstatat) to get its metadata.
//
// Does not close `fd`; the caller owns its lifetime.
func enumerateDirectoryBulk(fd: Int32) throws -> [BulkDirEntry] {
    var attrs = requestedAttrList
    var results: [BulkDirEntry] = []
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bulkBufferCapacity, alignment: 8)
    defer { buffer.deallocate() }
    guard let bufferBase = buffer.baseAddress else { throw BulkEnumerationUnavailable() }

    while true {
        let count = getattrlistbulk(fd, &attrs, bufferBase, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
        if count < 0 {
            if unsupportedBulkErrors.contains(errno) { throw BulkEnumerationUnavailable() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if count == 0 { break }

        try parseBulkBatch(
            bufferBase: UnsafeRawPointer(bufferBase),
            bufferByteCount: buffer.count,
            entryCount: Int(count),
            into: &results
        )
    }

    return results
}

// Fallback listing used when bulk enumeration is unavailable for a directory,
// or when `MDS_FORCE_FALLBACK_ENUM=1` forces it everywhere (parity testing).
// Uses the traditional readdir + fstatat path, duplicating `fd` so the
// caller's descriptor is unaffected by fdopendir's ownership rules.
func fallbackEnumerateDirectory(fd: Int32) throws -> [BulkDirEntry] {
    let duped = dup(fd)
    guard duped >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard let dir = fdopendir(duped) else {
        let openErrno = errno
        close(duped)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(openErrno))
    }
    defer { closedir(dir) }
    let dfd = dirfd(dir)

    var results: [BulkDirEntry] = []
    while let entry = readdir(dir) {
        let nameBytes = entry.pointee.d_name
        let name: String = withUnsafeBytes(of: nameBytes) { ptr in
            let bytes = ptr.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        guard name != "." && name != ".." else { continue }

        let dtype = entry.pointee.d_type
        // Fast path: these types never need a stat call, the scanner skips them regardless.
        if dtype == DT_LNK {
            results.append(BulkDirEntry(name: name, kind: .symlink, dev: 0, ino: 0, linkCount: 0, allocatedSize: 0))
            continue
        }
        if dtype == DT_FIFO || dtype == DT_CHR || dtype == DT_BLK || dtype == DT_SOCK {
            results.append(BulkDirEntry(name: name, kind: .other, dev: 0, ino: 0, linkCount: 0, allocatedSize: 0))
            continue
        }

        // DT_DIR / DT_REG / DT_UNKNOWN (some network/FUSE filesystems don't
        // populate d_type): resolve the real type via fstatat.
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
        let mode = st.st_mode & S_IFMT
        let kind: BulkEntryKind
        switch mode {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let allocatedSize = kind == .file ? Int64(st.st_blocks) * 512 : 0
        results.append(BulkDirEntry(
            name: name,
            kind: kind,
            dev: UInt64(bitPattern: Int64(st.st_dev)),
            ino: UInt64(st.st_ino),
            linkCount: UInt32(st.st_nlink),
            allocatedSize: allocatedSize
        ))
    }
    return results
}

// MARK: - getattrlistbulk buffer parsing

// Reads fixed-size fields out of one packed getattrlistbulk entry, advancing
// past each field's 4-byte-aligned footprint (matches the kernel's packing).
private struct AttributeCursor {
    var current: UnsafeRawPointer
    let end: UnsafeRawPointer

    mutating func read<T>() -> T? {
        let size = MemoryLayout<T>.size
        let alignedSize = (size + 3) & ~3
        guard alignedSize <= current.distance(to: end) else { return nil }
        let value = current.loadUnaligned(as: T.self)
        current = current.advanced(by: alignedSize)
        return value
    }
}

private func parseBulkBatch(
    bufferBase: UnsafeRawPointer,
    bufferByteCount: Int,
    entryCount: Int,
    into results: inout [BulkDirEntry]
) throws {
    let bufferEnd = bufferBase.advanced(by: bufferByteCount)
    var entryAddress = bufferBase

    for _ in 0..<entryCount {
        guard MemoryLayout<UInt32>.size <= entryAddress.distance(to: bufferEnd) else {
            throw BulkEnumerationUnavailable()
        }
        let entryLength = Int(entryAddress.loadUnaligned(as: UInt32.self))
        guard entryLength >= MemoryLayout<UInt32>.size,
              entryLength <= entryAddress.distance(to: bufferEnd) else {
            throw BulkEnumerationUnavailable()
        }
        let entryEnd = entryAddress.advanced(by: entryLength)

        if let entry = try parseBulkEntry(entryStart: entryAddress, entryEnd: entryEnd) {
            results.append(entry)
        }
        // else: this single entry had a per-entry error (ATTR_CMN_ERROR set,
        // e.g. a race with deletion) - skip it, keep parsing the batch.
        entryAddress = entryEnd
    }
}

// Parses one packed entry. Field order (for the attributes requested above)
// follows getattrlist(2)'s fixed declaration order: ATTR_CMN_RETURNED_ATTRS,
// ATTR_CMN_ERROR, ATTR_CMN_NAME (attrreference_t), ATTR_CMN_DEVID,
// ATTR_CMN_OBJTYPE, ATTR_CMN_FILEID, then (regular files only)
// ATTR_FILE_LINKCOUNT, ATTR_FILE_ALLOCSIZE.
private func parseBulkEntry(entryStart: UnsafeRawPointer, entryEnd: UnsafeRawPointer) throws -> BulkDirEntry? {
    var cursor = AttributeCursor(current: entryStart.advanced(by: MemoryLayout<UInt32>.size), end: entryEnd)

    guard let returned: attribute_set_t = cursor.read(),
          let entryError: UInt32 = cursor.read() else {
        throw BulkEnumerationUnavailable()
    }

    let nameRefAddress = cursor.current
    guard let nameRef: attrreference_t = cursor.read() else { throw BulkEnumerationUnavailable() }
    guard let name = parseBulkName(reference: nameRef, referenceAddress: nameRefAddress, entryEnd: entryEnd) else {
        throw BulkEnumerationUnavailable()
    }

    guard let deviceID: dev_t = cursor.read(),
          let objectType: fsobj_type_t = cursor.read(),
          let fileID: UInt64 = cursor.read() else {
        throw BulkEnumerationUnavailable()
    }

    // A per-entry error means the filesystem couldn't produce metadata for
    // this one child (e.g. deleted mid-listing); skip only this entry.
    if entryError != 0 { return nil }

    guard returned.commonattr & requiredCommonAttrs == requiredCommonAttrs else {
        throw BulkEnumerationUnavailable()
    }

    let kind: BulkEntryKind
    if objectType == VDIR.rawValue { kind = .directory }
    else if objectType == VREG.rawValue { kind = .file }
    else if objectType == VLNK.rawValue { kind = .symlink }
    else { kind = .other }

    var linkCount: UInt32 = 1
    var allocatedSize: Int64 = 0
    if kind == .file {
        // File attributes are only present in the buffer for regular files.
        guard returned.fileattr & requiredFileAttrs == requiredFileAttrs else {
            throw BulkEnumerationUnavailable()
        }
        guard let readLinkCount: UInt32 = cursor.read(),
              let readAllocSize: off_t = cursor.read() else {
            throw BulkEnumerationUnavailable()
        }
        linkCount = readLinkCount
        allocatedSize = Int64(readAllocSize)
    }

    return BulkDirEntry(
        name: name,
        kind: kind,
        dev: UInt64(bitPattern: Int64(deviceID)),
        ino: fileID,
        linkCount: linkCount,
        allocatedSize: max(allocatedSize, 0)
    )
}

// `attr_dataoffset` is relative to the attrreference_t's own address.
private func parseBulkName(
    reference: attrreference_t,
    referenceAddress: UnsafeRawPointer,
    entryEnd: UnsafeRawPointer
) -> String? {
    guard reference.attr_dataoffset >= 0 else { return nil }
    let dataOffset = Int(reference.attr_dataoffset)
    guard dataOffset <= referenceAddress.distance(to: entryEnd) else { return nil }
    let start = referenceAddress.advanced(by: dataOffset)
    let byteCount = Int(reference.attr_length)
    guard byteCount > 0, byteCount <= start.distance(to: entryEnd) else { return nil }

    let bytes = UnsafeRawBufferPointer(start: start, count: byteCount)
    // The name is NUL-terminated; trim the trailing NUL before decoding.
    let stringByteCount = bytes.last == 0 ? byteCount - 1 : byteCount
    guard stringByteCount > 0 else { return nil }
    let nameBytes = UnsafeRawBufferPointer(start: start, count: stringByteCount).bindMemory(to: UInt8.self)
    guard let name = String(bytes: nameBytes, encoding: .utf8), name.utf8.count == stringByteCount else {
        return nil
    }
    return name
}
