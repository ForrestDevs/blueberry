import Foundation

/// Decodes `message.attributedBody`, a typedstream (NSArchiver) encoded NSAttributedString.
/// Since Ventura, many messages have NULL `text` and only carry their content here.
public enum AttributedBody {
    public static func text(from data: Data) -> String? {
        // NSUnarchiver is deprecated but is the native reader for typedstream; Messages still writes it.
        guard let object = NSUnarchiver.unarchiveObject(with: data) else { return nil }
        let string: String
        if let attributed = object as? NSAttributedString {
            string = attributed.string
        } else if let plain = object as? String {
            string = plain
        } else {
            return nil
        }
        // U+FFFC marks inline attachments; strip it so text-only consumers see clean content.
        let cleaned = string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
