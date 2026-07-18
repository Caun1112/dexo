import Foundation

nonisolated struct HTTPProxyRequestParser {
    struct Header: Equatable, Sendable {
        let name: String
        let value: String
    }

    struct Request: Equatable, Sendable {
        let method: String
        let target: String
        let headers: [Header]
        let body: Data

        func values(forHeader name: String) -> [String] {
            headers.compactMap { header in
                header.name.caseInsensitiveCompare(name) == .orderedSame ? header.value : nil
            }
        }
    }

    enum ParseError: Error, Equatable {
        case malformedRequest
        case headerTooLarge
        case bodyTooLarge
        case unsupportedTransferEncoding
    }

    private static let headerDelimiter = Data("\r\n\r\n".utf8)
    private static let maximumHeaderSize = 64 * 1024
    private static let maximumBodySize = 32 * 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) throws {
        guard buffer.count <= Self.maximumHeaderSize + Self.maximumBodySize - data.count else {
            throw ParseError.bodyTooLarge
        }
        buffer.append(data)
    }

    mutating func nextRequest() throws -> Request? {
        guard let headerRange = buffer.range(of: Self.headerDelimiter) else {
            if buffer.count > Self.maximumHeaderSize {
                throw ParseError.headerTooLarge
            }
            return nil
        }

        guard headerRange.upperBound <= Self.maximumHeaderSize else {
            throw ParseError.headerTooLarge
        }
        let headerData = Data(buffer[..<headerRange.lowerBound])
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw ParseError.malformedRequest
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParseError.malformedRequest
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0"
        else {
            throw ParseError.malformedRequest
        }

        let method = String(requestParts[0])
        let target = String(requestParts[1])
        guard Self.isValidToken(method),
              !target.isEmpty,
              !target.contains(where: { $0.isWhitespace || $0.isNewline })
        else {
            throw ParseError.malformedRequest
        }

        var headers: [Header] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " " && line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else {
                throw ParseError.malformedRequest
            }

            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidToken(name),
                  !value.contains("\r"),
                  !value.contains("\n")
            else {
                throw ParseError.malformedRequest
            }
            headers.append(Header(name: name, value: value))
        }

        let transferEncodings = headers
            .filter { $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard transferEncodings.isEmpty else {
            throw ParseError.unsupportedTransferEncoding
        }

        let contentLengthValues = headers
            .filter { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let distinctContentLengths = Set(contentLengthValues)
        guard distinctContentLengths.count <= 1,
              let contentLength = distinctContentLengths.first.flatMap(Int.init) ?? (contentLengthValues.isEmpty ? 0 : nil),
              contentLength >= 0
        else {
            throw ParseError.malformedRequest
        }
        guard contentLength <= Self.maximumBodySize else {
            throw ParseError.bodyTooLarge
        }

        let requestEnd = headerRange.upperBound + contentLength
        guard buffer.count >= requestEnd else { return nil }

        let body = Data(buffer[headerRange.upperBound..<requestEnd])
        buffer.removeSubrange(..<requestEnd)
        return Request(method: method, target: target, headers: headers, body: body)
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 31 && scalar.value != 127 && !separators.contains(scalar)
        }
    }
}
