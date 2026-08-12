import AppKit
import UniformTypeIdentifiers

/// Ways to bring an image in for a project icon: the clipboard or a file picker.
enum ImageIntake {
    /// An image (or an image file) currently on the pasteboard, if any.
    static func fromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            return first
        }
        // A copied image *file* comes through as a URL.
        let opts: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
           let url = urls.first {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    static var pasteboardHasImage: Bool {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        let opts: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        return pb.canReadObject(forClasses: [NSURL.self], options: opts)
    }

    /// Prompt for an image file.
    static func chooseFile() -> NSImage? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.message = "Choose an image to use as this project's icon."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return NSImage(contentsOf: url)
    }
}
