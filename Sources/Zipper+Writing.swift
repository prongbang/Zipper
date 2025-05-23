
import Foundation

public extension Zipper {
    private enum ModifyOperation: Int {
        case remove = -1
        case add = 1
    }

    /// Write files, directories or symlinks to the receiver.
    ///
    /// - Parameters:
    ///   - path: The path that is used to identify an `Zipper.Entry` within the `Zipper` file.
    ///   - baseURL: The base URL of the `Zipper.Entry` to add.
    ///              The `baseURL` combined with `path` must form a fully qualified file URL.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied to `Zipper.Entry`.
    ///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
    /// - Throws: An error if the source file cannot be read or the receiver is not writable.
    func addEntry(with path: String, relativeTo baseURL: URL, compressionMethod: CompressionMethod = .none,
                         bufferSize: UInt32 = defaultWriteChunkSize) throws {
        let fileManager = FileManager()
        let entryURL = baseURL.appendingPathComponent(path)
        guard fileManager.isReadableFile(atPath: entryURL.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        let type = try FileManager.typeForItem(at: entryURL)
        let modDate = try FileManager.fileModificationDateTimeForItem(at: entryURL)
        let uncompressedSize = type == .directory ? 0 : try FileManager.fileSizeForItem(at: entryURL)
        let permissions = try FileManager.permissionsForItem(at: entryURL)
        var provider: ZipperProviderClosure
        switch type {
        case .file:
            let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: entryURL.path)
            let entryFile: UnsafeMutablePointer<FILE> = fopen(entryFileSystemRepresentation, "rb")
            defer { fclose(entryFile) }
            provider = { _, _ in return try Data.readChunk(from: entryFile, size: Int(bufferSize)) }
            try self.addEntry(with: path, type: type, uncompressedSize: uncompressedSize,
                              modificationDate: modDate, permissions: permissions,
                              compressionMethod: compressionMethod, bufferSize: bufferSize, provider: provider)
        case .directory:
            provider = { _, _ in return Data() }
            try self.addEntry(with: path.hasSuffix("/") ? path : path + "/",
                              type: type, uncompressedSize: uncompressedSize,
                              modificationDate: modDate, permissions: permissions,
                              compressionMethod: compressionMethod, bufferSize: bufferSize, provider: provider)
        case .symlink:
            provider = { _, _ -> Data in
                let fileManager = FileManager()
                let path = entryURL.path
                let linkDestination = try fileManager.destinationOfSymbolicLink(atPath: path)
                let linkFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: linkDestination)
                let linkLength = Int(strlen(linkFileSystemRepresentation))
                let linkBuffer = UnsafeBufferPointer(start: linkFileSystemRepresentation, count: linkLength)
                let linkData = Data.init(buffer: linkBuffer)
                return linkData
            }
            try self.addEntry(with: path, type: type, uncompressedSize: uncompressedSize,
                              modificationDate: modDate, permissions: permissions,
                              compressionMethod: compressionMethod, bufferSize: bufferSize, provider: provider)
        }
    }

    /// Write files, directories or symlinks to the receiver.
    ///
    /// - Parameters:
    ///   - path: The path that is used to identify an `Zipper.Entry` within the `Zipper` file.
    ///   - type: Indicates the `Zipper.Entry.EntryType` of the added content.
    ///   - uncompressedSize: The uncompressed size of the data that is going to be added with `provider`.
    ///   - modificationDate: A `Date` describing the file modification date of the `Zipper.Entry`.
    ///                       Default is the current `Date`.
    ///   - permissions: POSIX file permissions for the `Zipper.Entry`.
    ///                  Default is `0`o`755`.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied to `Zipper.Entry`.
    ///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
    ///   - provider: A closure that accepts a position and a chunk size. Returns a `Data` chunk.
    /// - Throws: An error if the source data is invalid or the receiver is not writable.
    func addEntry(with path: String, type: Zipper.Entry.EntryType, uncompressedSize: UInt32,
                         modificationDate: Date = Date(),
                         permissions: UInt16 = defaultPermissions,
                         compressionMethod: CompressionMethod = .none, bufferSize: UInt32 = defaultWriteChunkSize,
                         provider: ZipperProviderClosure) throws {
        guard self.accessMode != .read else { throw ArchiveError.unwritableArchive }
        var endOfCentralDirectoryRecord = self.endOfCentralDirectoryRecord
        var startOfCentralDirectory = Int(endOfCentralDirectoryRecord.offsetToStartOfCentralDirectory)
        var existingCentralDirectoryData = Data()
        fseek(self.archiveFile, startOfCentralDirectory, SEEK_SET)
        existingCentralDirectoryData = try Data.readChunk(from: self.archiveFile,
                                                          size: Int(endOfCentralDirectoryRecord.sizeOfCentralDirectory))
        fseek(self.archiveFile, startOfCentralDirectory, SEEK_SET)
        let localFileHeaderStart = ftell(self.archiveFile)
        let modDateTime = modificationDate.fileModificationDateTime
        var localFileHeader = try self.writeLocalFileHeader(path: path, compressionMethod: compressionMethod,
                                                            size: (uncompressedSize, 0), checksum: 0,
                                                            modificationDateTime: modDateTime)
        let (sizeWritten, checksum)  = try self.writeEntry(localFileHeader: localFileHeader, type: type,
                                                           compressionMethod: compressionMethod,
                                                           bufferSize: bufferSize, provider: provider)
        startOfCentralDirectory = ftell(self.archiveFile)
        fseek(self.archiveFile, localFileHeaderStart, SEEK_SET)
        // Write the local file header a second time. Now with compressedSize (if applicable) and a valid checksum.
        localFileHeader = try self.writeLocalFileHeader(path: path, compressionMethod: compressionMethod,
                                                        size: (uncompressedSize, sizeWritten),
                                                        checksum: checksum, modificationDateTime: modDateTime)
        fseek(self.archiveFile, startOfCentralDirectory, SEEK_SET)
        _ = try Data.write(chunk: existingCentralDirectoryData, to: self.archiveFile)
        let externalFileAttributes = FileManager.externalFileAttributesForEntry(of: type, permissions: permissions)
        let offset = UInt32(localFileHeaderStart)
        let centralDirectory = try self.writeCentralDirectoryStructure(localFileHeader: localFileHeader,
                                                                       relativeOffset: offset,
                                                                       externalFileAttributes: externalFileAttributes)
        // FIXME: integer overflows when converted from UInt32 to Int: Int(UInt32.max)
        if UInt32(startOfCentralDirectory) > UInt32.max {
            throw ArchiveError.invalidStartOfCentralDirectoryOffset
        }
        let start = UInt32(startOfCentralDirectory)
        endOfCentralDirectoryRecord = try self.writeEndOfCentralDirectory(centralDirectoryStructure: centralDirectory,
                                                                          startOfCentralDirectory: start,
                                                                          operation: .add)
        fflush(self.archiveFile)
        self.endOfCentralDirectoryRecord = endOfCentralDirectoryRecord
    }

    /// Remove a ZIP `Zipper.Entry` from the receiver.
    ///
    /// - Parameters:
    ///   - entry: The `Zipper.Entry` to remove.
    ///   - bufferSize: The maximum size for the read and write buffers used during removal.
    /// - Throws: An error if the `Zipper.Entry` is malformed or the receiver is not writable.
    func remove(_ entry: Zipper.Entry, bufferSize: UInt32 = defaultReadChunkSize) throws {
        let uniqueString = ProcessInfo.processInfo.globallyUniqueString
        let tempArchiveURL =  URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uniqueString)
        guard let tempArchive = Zipper(url: tempArchiveURL, accessMode: .create) else {
            throw ArchiveError.unwritableArchive
        }
        var centralDirectoryData = Data()
        var offset = 0
        for currentEntry in self {
            let localFileHeader = currentEntry.localFileHeader
            let centralDirectoryStructure = currentEntry.centralDirectoryStructure
            let dataDescriptor = currentEntry.dataDescriptor
            var extraDataLength = Int(localFileHeader.fileNameLength)
            extraDataLength += Int(localFileHeader.extraFieldLength)
            var entrySize = LocalFileHeader.size + extraDataLength
            let isCompressed = centralDirectoryStructure.compressionMethod != CompressionMethod.none.rawValue
            if let dataDescriptor = dataDescriptor {
                entrySize += Int(isCompressed ? dataDescriptor.compressedSize : dataDescriptor.uncompressedSize)
                entrySize += DataDescriptor.size
            } else {
                entrySize += Int(isCompressed ? localFileHeader.compressedSize : localFileHeader.uncompressedSize)
            }
            if currentEntry != entry {
                let entryStart = Int(currentEntry.centralDirectoryStructure.relativeOffsetOfLocalHeader)
                fseek(self.archiveFile, entryStart, SEEK_SET)
                let consumer = { _ = try Data.write(chunk: $0, to: tempArchive.archiveFile) }
                _ = try Data.consumePart(of: self.archiveFile, size: Int(entrySize), chunkSize: Int(bufferSize),
                                         skipCRC32: true, consumer: consumer)
                let centralDir = CentralDirectoryStructure(centralDirectoryStructure: centralDirectoryStructure,
                                                           offset: UInt32(offset))
                centralDirectoryData.append(centralDir.data)
            } else { offset = entrySize }
        }
        let startOfCentralDirectory = ftell(tempArchive.archiveFile)
        _ = try Data.write(chunk: centralDirectoryData, to: tempArchive.archiveFile)
        tempArchive.endOfCentralDirectoryRecord = self.endOfCentralDirectoryRecord
        let endOfCentralDirectoryRecord = try
            tempArchive.writeEndOfCentralDirectory(centralDirectoryStructure: entry.centralDirectoryStructure,
                                                   startOfCentralDirectory: UInt32(startOfCentralDirectory),
                                                   operation: .remove)
        tempArchive.endOfCentralDirectoryRecord = endOfCentralDirectoryRecord
        self.endOfCentralDirectoryRecord = endOfCentralDirectoryRecord
        fflush(tempArchive.archiveFile)
        try self.replaceCurrentArchiveWithArchive(at: tempArchive.url)
    }

    // MARK: - Helpers

    private func writeLocalFileHeader(path: String, compressionMethod: CompressionMethod,
                                      size: (uncompressed: UInt32, compressed: UInt32),
                                      checksum: ZipperCRC32,
                                      modificationDateTime: (UInt16, UInt16)) throws -> LocalFileHeader {
        let fileManager = FileManager()
        let fileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: path)
        let fileNameLength = Int(strlen(fileSystemRepresentation))
        let fileNameBuffer = UnsafeBufferPointer(start: fileSystemRepresentation, count: fileNameLength)
        let fileNameData = Data.init(buffer: fileNameBuffer)
        let localFileHeader = LocalFileHeader(versionNeededToExtract: UInt16(20), generalPurposeBitFlag: UInt16(2048),
                                              compressionMethod: compressionMethod.rawValue,
                                              lastModFileTime: modificationDateTime.1,
                                              lastModFileDate: modificationDateTime.0, crc32: checksum,
                                              compressedSize: size.compressed, uncompressedSize: size.uncompressed,
                                              fileNameLength: UInt16(fileNameLength), extraFieldLength: UInt16(0),
                                              fileNameData: fileNameData, extraFieldData: Data())
        _ = try Data.write(chunk: localFileHeader.data, to: self.archiveFile)
        return localFileHeader
    }

    private func writeEntry(localFileHeader: LocalFileHeader, type: Zipper.Entry.EntryType,
                            compressionMethod: CompressionMethod, bufferSize: UInt32,
                            provider: ZipperProviderClosure) throws -> (sizeWritten: UInt32, crc32: ZipperCRC32) {
        var checksum = ZipperCRC32(0)
        var sizeWritten = UInt32(0)
        switch type {
        case .file:
            switch compressionMethod {
            case .none:
                (sizeWritten, checksum) = try self.writeUncompressed(size: localFileHeader.uncompressedSize,
                                                                     bufferSize: bufferSize, provider: provider)
            case .deflate:
                (sizeWritten, checksum) = try self.writeCompressed(size: localFileHeader.uncompressedSize,
                                                                   bufferSize: bufferSize, provider: provider)
            }
        case .directory: _ = try provider(0, 0)
        case .symlink:
            (sizeWritten, checksum) = try self.writeSymbolicLink(size: localFileHeader.uncompressedSize,
                                                                 provider: provider)
        }
        return (sizeWritten, checksum)
    }

    private func writeUncompressed(size: UInt32, bufferSize: UInt32,
                                   provider: ZipperProviderClosure) throws -> (sizeWritten: UInt32, checksum: ZipperCRC32) {
        var position = 0
        var sizeWritten = 0
        var checksum = ZipperCRC32(0)
        while position < Int(size) {
            let readSize = (Int(size) - position) >= Int(bufferSize) ? Int(bufferSize) : (Int(size) - position)
            let entryChunk = try provider(Int(position), Int(readSize))
            checksum = entryChunk.crc32(checksum: checksum)
            sizeWritten += try Data.write(chunk: entryChunk, to: self.archiveFile)
            position += Int(bufferSize)
        }
        return (UInt32(sizeWritten), checksum)
    }

    private func writeCompressed(size: UInt32, bufferSize: UInt32,
                                 provider: ZipperProviderClosure) throws -> (sizeWritten: UInt32, checksum: ZipperCRC32) {
        var sizeWritten = 0
        let checksum = try Data.compress(size: Int(size), bufferSize: Int(bufferSize), provider: provider) { data in
            sizeWritten += try Data.write(chunk: data, to: self.archiveFile)
        }
        return(UInt32(sizeWritten), checksum)
    }

    private func writeSymbolicLink(size: UInt32, provider: ZipperProviderClosure) throws -> (sizeWritten: UInt32, checksum: ZipperCRC32) {
        let linkData = try provider(0, Int(size))
        let checksum = linkData.crc32(checksum: 0)
        let sizeWritten = try Data.write(chunk: linkData, to: self.archiveFile)
        return (UInt32(sizeWritten), checksum)
    }

    private func writeCentralDirectoryStructure(localFileHeader: LocalFileHeader, relativeOffset: UInt32,
                                                externalFileAttributes: UInt32) throws -> CentralDirectoryStructure {
        let centralDirectory = CentralDirectoryStructure(localFileHeader: localFileHeader,
                                                         fileAttributes: externalFileAttributes,
                                                         relativeOffset: relativeOffset)
        _ = try Data.write(chunk: centralDirectory.data, to: self.archiveFile)
        return centralDirectory
    }

    private func writeEndOfCentralDirectory(centralDirectoryStructure: CentralDirectoryStructure,
                                            startOfCentralDirectory: UInt32,
                                            operation: ModifyOperation) throws -> EndOfCentralDirectoryRecord {
        var record = self.endOfCentralDirectoryRecord
        let countChange = operation.rawValue
        var dataLength = centralDirectoryStructure.extraFieldLength
        dataLength += centralDirectoryStructure.fileNameLength
        dataLength += centralDirectoryStructure.fileCommentLength
        let centralDirectoryDataLengthChange = operation.rawValue * (Int(dataLength) + CentralDirectoryStructure.size)
        var updatedSizeOfCentralDirectory = Int(record.sizeOfCentralDirectory)
        updatedSizeOfCentralDirectory += centralDirectoryDataLengthChange
        let numberOfEntriesOnDisk = UInt16(Int(record.totalNumberOfEntriesOnDisk) + countChange)
        let numberOfEntriesInCentralDirectory = UInt16(Int(record.totalNumberOfEntriesInCentralDirectory) + countChange)
        record = EndOfCentralDirectoryRecord(record: record, numberOfEntriesOnDisk: numberOfEntriesOnDisk,
                                             numberOfEntriesInCentralDirectory: numberOfEntriesInCentralDirectory,
                                             updatedSizeOfCentralDirectory: UInt32(updatedSizeOfCentralDirectory),
                                             startOfCentralDirectory: startOfCentralDirectory)
        _ = try Data.write(chunk: record.data, to: self.archiveFile)
        return record
    }

    private func replaceCurrentArchiveWithArchive(at URL: URL) throws {
        fclose(self.archiveFile)
        let fileManager = FileManager()
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
            _ = try fileManager.replaceItemAt(self.url, withItemAt: URL)
#else
            _ = try fileManager.removeItem(at: self.url)
            _ = try fileManager.moveItem(at: URL, to: self.url)
#endif
        let fileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: self.url.path)
        self.archiveFile = fopen(fileSystemRepresentation, "rb+")
    }
}

extension Zipper {
    /// Zips the file or direcory contents at the specified source URL to the destination URL.
    ///
    /// If the item at the source URL is a directory, the directory itself will be
    /// represented within the ZIP `Zipper`. Calling this method with a directory URL
    /// `file:///path/directory/` will create an archive with a `directory/` entry at the root level.
    /// You can override this behavior by passing `false` for `shouldKeepParent`. In that case, the contents
    /// of the source directory will be placed at the root of the archive.
    /// - Parameters:
    ///   - sourceURL: The file URL pointing to an existing file or directory.
    ///   - shouldKeepParent: Indicates that the directory name of a source item should be used as root element
    ///                       within the archive. Default is `true`.
    /// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
    public func archive(item sourceURL: URL, shouldKeepParent: Bool = true) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue,
                          userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        let isDirectory = try FileManager.typeForItem(at: sourceURL) == .directory
        if isDirectory {
            // Use the path based enumerator because it returns String objects containing
            // relative paths instead of absolute URLs
            let dirEnumerator = FileManager.default.enumerator(atPath: sourceURL.path)
            // If the caller wants to keep the parent directory, we use the lastPathComponent of the source URL
            // as common base for all entries (similar to macOS' Archive Utility.app)
            let directoryPrefix = sourceURL.lastPathComponent
            while let entryPath = dirEnumerator?.nextObject() as? String {
                let finalEntryPath = shouldKeepParent ? directoryPrefix + "/" + entryPath : entryPath
                try self.addEntry(with: finalEntryPath, relativeTo: sourceURL.deletingLastPathComponent())
            }
        } else {
            let baseURL = sourceURL.deletingLastPathComponent()
            try self.addEntry(with: sourceURL.lastPathComponent, relativeTo: baseURL)
        }
    }
    
    /// Zips the file or direcory contents at the specified source URL to the destination URL.
    ///
    /// If the item at the source URL is a directory, the directory itself will be
    /// represented within the ZIP `Zipper`. Calling this method with a directory URL
    /// `file:///path/directory/` will create an archive with a `directory/` entry at the root level.
    /// You can override this behavior by passing `false` for `shouldKeepParent`. In that case, the contents
    /// of the source directory will be placed at the root of the archive.
    /// - Parameters:
    ///   - sourceURL: The file URL pointing to an existing file or directory.
    ///   - shouldKeepParent: Indicates that the directory name of a source item should be used as root element
    ///                       within the archive. Default is `true`.
    /// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
    public func zip(item sourceURL: URL, shouldKeepParent: Bool = true) throws {
        try archive(item: sourceURL, shouldKeepParent: shouldKeepParent)
    }
}