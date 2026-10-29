import Foundation

public enum UpstreamLicense {
    public static func text() throws -> String {
        guard let url = Bundle.module.url(forResource: "LICENSE", withExtension: "upstream") else {
            throw UnpurpleError("missing upstream license resource")
        }
        return try String(contentsOf: url)
    }
}
