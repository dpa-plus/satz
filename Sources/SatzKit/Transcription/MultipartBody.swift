import Foundation

/// Builds a `multipart/form-data` body.
///
/// Separate and pure so the exact bytes on the wire can be tested. A malformed
/// multipart body fails as an opaque 400 from the server, which is miserable to
/// debug from the outside.
struct MultipartBody {
    let boundary: String

    init(boundary: String = "satz-" + UUID().uuidString) {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// - Parameters:
    ///   - fields: plain text form fields, written in the given order.
    ///   - file: the upload, or nil for a body with no file part.
    func encode(fields: [(name: String, value: String)],
                file: (name: String, filename: String, mimeType: String, data: Data)?) -> Data {
        var body = Data()

        for field in fields {
            body.append(line: "--\(boundary)")
            body.append(line: "Content-Disposition: form-data; name=\"\(field.name)\"")
            body.append(line: "")
            body.append(line: field.value)
        }

        if let file {
            body.append(line: "--\(boundary)")
            body.append(
                line: "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\""
            )
            body.append(line: "Content-Type: \(file.mimeType)")
            body.append(line: "")
            body.append(file.data)
            body.append(line: "")
        }

        body.append(line: "--\(boundary)--")
        return body
    }
}

private extension Data {
    /// Appends `text` followed by CRLF, which multipart requires. A bare LF is
    /// accepted by some servers and rejected by others.
    mutating func append(line text: String) {
        append(contentsOf: Array(text.utf8))
        append(contentsOf: [0x0D, 0x0A])
    }
}
