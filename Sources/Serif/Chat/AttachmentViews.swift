import SwiftUI
import AppKit
import ImageIO
import SerifCore

/// Where an attachment lives: its path in the project's shared folder (spec §4 of 0.7).
func attachmentURL(_ path: String, project: UUID) -> URL {
    SerifPaths.standard().shared(project).appendingPathComponent(path)
}

/// A file's size as the app shows it ("1,2 MB").
func fileSizeText(_ bytes: Int) -> String { Int64(bytes).formatted(.byteCount(style: .file)) }

/// The files under a message of yours (spec §4): a thumbnail for an image, a row with icon, name and size for the rest;
/// a click opens the file with its app; one gone from the disk says so.
struct AttachmentList: View {
    let paths: [String]
    let project: UUID

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                let url = attachmentURL(path, project: project)
                if !FileManager.default.fileExists(atPath: url.path) {
                    row(icon: Image(systemName: "doc.questionmark"), name: url.lastPathComponent,
                        detail: String(localized: "file no longer available"), url: nil)
                } else if isImage(path) {
                    AttachmentThumb(url: url)
                } else {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    row(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)), name: url.lastPathComponent,
                        detail: fileSizeText(size), url: url)
                }
            }
        }
    }

    private func row(icon: Image, name: String, detail: String, url: URL?) -> some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 8) {
                icon.resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: Theme.Size.small, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: Theme.Size.caption)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.botBubble))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain).disabled(url == nil).opacity(url == nil ? 0.6 : 1).help(url?.path ?? "")
    }
}

/// An image attachment, downsampled from the file (never the whole picture in memory), opened with a click.
struct AttachmentThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(Theme.textTertiary).frame(width: 120, height: 90)
                }
            }
            .frame(maxWidth: 240, maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).stroke(Theme.borderTertiary, lineWidth: 1))
        }
        .buttonStyle(.plain).help(url.lastPathComponent)
        .task { image = await Task.detached { Self.thumbnail(url) }.value }
    }

    /// ImageIO's thumbnail, 480 px on its longer side at most: a 16 MB photo costs a few hundred KB here.
    nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// A file chosen in the composer, not sent yet (spec §4): name, size, ×.
struct AttachmentChip: View {
    let file: AttachedFile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isImage(file.name) ? "photo" : "doc").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text(file.name).font(.system(size: Theme.Size.label)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
            Text(fileSizeText(file.data.count)).font(.system(size: Theme.Size.caption)).foregroundStyle(Theme.textTertiary)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(String(localized: "Remove"))
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(Capsule().fill(Theme.fillSecondary))
        .overlay(Capsule().stroke(Theme.borderTertiary, lineWidth: 1))
    }
}

/// What ⌘V brings (spec §4): files from the Finder (read later, off the main thread), else a picture (a screenshot)
/// as a PNG named by the time. Nothing for text, which the field pastes itself, even when a picture comes with it.
func pastedFiles(_ pasteboard: NSPasteboard = .general) -> (urls: [URL], image: AttachedFile?) {
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        return (urls, nil)
    }
    guard pasteboard.types?.contains(.string) != true,
          let tiff = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return ([], nil) }
    let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute().second())
        .filter(\.isNumber)
    return ([], AttachedFile(name: "clipboard-\(stamp).png", data: png))
}

/// Reads `urls` off the main thread: folders and unreadable files are left out, files over 16 MB are not read at all
/// (their names come back apart, for the error).
func loadFiles(_ urls: [URL]) async -> (files: [AttachedFile], tooBig: [String]) {
    await Task.detached {
        var result: (files: [AttachedFile], tooBig: [String]) = ([], [])
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory == false, let size = values?.fileSize else { continue }
            if size > AttachmentRules.maxBytes { result.tooBig.append(url.lastPathComponent); continue }
            if let data = try? Data(contentsOf: url) { result.files.append(AttachedFile(name: url.lastPathComponent, data: data)) }
        }
        return result
    }.value
}
