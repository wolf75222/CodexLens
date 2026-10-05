import Foundation
import ImageIO

/// Decodes recorded inline image bytes. It never resolves a URL, fetches a resource,
/// writes a file, or substitutes another attachment when the requested one is absent.
public enum EmbeddedResource {
    public enum DecodeError: LocalizedError, Sendable {
        case invalidReference, unavailable, malformedRecord, unsupportedFormat
        case invalidBase64, invalidImage, tooLarge, ambiguousRecords
        public var errorDescription: String? {
            switch self {
            case .invalidReference: return "La ressource ne désigne pas un index précis de pièce jointe dans son événement d’origine."
            case .unavailable: return "Les octets de cette pièce jointe ne sont pas présents dans l’événement enregistré."
            case .malformedRecord: return "La trace JSON de la pièce jointe est incomplète ou invalide."
            case .unsupportedFormat: return "Seules les images PNG, JPEG, GIF, WebP et HEIC intégrées en base64 sont prises en charge. Aucun lien externe n’est téléchargé."
            case .invalidBase64: return "Les octets base64 de l’image enregistrée sont invalides."
            case .invalidImage: return "Les octets enregistrés ne constituent pas une image du format déclaré."
            case .tooLarge: return "L’image intégrée dépasse la limite de 32 Mio, ou sa trace dépasse la limite de lecture de 64 Mio."
            case .ambiguousRecords: return "Plusieurs enregistrements désignent des images différentes au même index. L’origine ne peut pas être déterminée sans ambiguïté."
            }
        }
    }

    private static let maximumDecodedBytes = 32 * 1024 * 1024
    private static let maximumRawBytes = 64 * 1024 * 1024

    public static func decodeImage(resource: ResourceRecord, detail: EventDetail) throws -> Data {
        guard resource.location.hasPrefix("trace:"),
              let marker = resource.location.range(of: ":attachment:", options: .backwards) else {
            throw DecodeError.invalidReference
        }
        let sourceID = String(resource.location[resource.location.index(resource.location.startIndex, offsetBy: 6)..<marker.lowerBound])
        let suffix = resource.location[marker.upperBound...]
        guard !sourceID.isEmpty, !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
              let index = Int(suffix), index >= 0,
              resource.eventIDs.isEmpty || resource.eventIDs.contains(sourceID) else {
            throw DecodeError.invalidReference
        }
        guard detail.raw.utf8.count <= maximumRawBytes else { throw DecodeError.tooLarge }
        var candidates = Set<String>()
        // Original records are single-line JSON; EventDetail separates its source records by blank lines.
        for line in detail.raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let recordText = line.trimmingCharacters(in: .whitespaces)
            if recordText.isEmpty { continue }
            guard let recordData = recordText.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any] else {
                throw DecodeError.malformedRecord
            }
            guard let payload = record["payload"] as? [String: Any] else { continue }
            let message: [String: Any]
            if payload["type"] as? String == "item_completed" {
                guard let item = payload["item"] as? [String: Any] else { continue }
                message = item
            } else { message = payload }
            guard let parts = message["content"] as? [[String: Any]], index < parts.count else { continue }
            let part = parts[index]
            guard ["input_image", "image", "localImage", "local_image"].contains(part["type"] as? String ?? "") else { continue }
            if let url = part["image_url"] as? String ?? (part["image_url"] as? [String: Any])?["url"] as? String {
                candidates.insert(url)
            }
        }
        guard !candidates.isEmpty else { throw DecodeError.unavailable }
        guard candidates.count == 1, let uri = candidates.first else { throw DecodeError.ambiguousRecords }
        guard let comma = uri.firstIndex(of: ","), uri[..<comma].utf8.count <= 128 else { throw DecodeError.unsupportedFormat }
        let header = uri[..<comma].lowercased()
        let supported = ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64", "data:image/heic;base64"]
        guard supported.contains(header) else { throw DecodeError.unsupportedFormat }
        let encoded = uri[uri.index(after: comma)...]
        let encodedCount = encoded.utf8.count
        let largestEncoding = ((maximumDecodedBytes + 2) / 3) * 4
        guard encodedCount <= largestEncoding else { throw DecodeError.tooLarge }
        guard encodedCount > 0, encodedCount % 4 == 0,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61 }) else {
            throw DecodeError.invalidBase64
        }
        let padding = encoded.suffix(2).filter { $0 == "=" }.count
        guard encodedCount / 4 * 3 - padding <= maximumDecodedBytes else { throw DecodeError.tooLarge }
        guard let data = Data(base64Encoded: String(encoded)), !data.isEmpty else { throw DecodeError.invalidBase64 }
        guard data.count <= maximumDecodedBytes else { throw DecodeError.tooLarge }
        guard matchesSignature(data, header: header),
              let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0 else { throw DecodeError.invalidImage }
        return data
    }

    private static func matchesSignature(_ data: Data, header: String) -> Bool {
        let bytes = Array(data.prefix(64))
        switch header {
        case "data:image/png;base64": return bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "data:image/jpeg;base64": return bytes.starts(with: [255, 216, 255])
        case "data:image/gif;base64":
            return bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8))
        case "data:image/webp;base64":
            return bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
        case "data:image/heic;base64":
            guard bytes.count >= 16, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }
            let brands = ["heic", "heix", "hevc", "hevx"].map { Array($0.utf8) }
            for offset in stride(from: 8, through: bytes.count - 4, by: 4) where offset != 12 {
                if brands.contains(Array(bytes[offset..<(offset + 4)])) { return true }
            }
            return false
        default: return false
        }
    }
}
