import CryptoKit
import Foundation

/// An encrypted, bounded index of committed text exposed by a saved document's editor.
/// The actor keeps file I/O and matching out of the keyboard event path.
public actor DocumentMemoryStore {
    private static let keychainService = "com.pattonium.KeyType.dev.document-memory"
    private static let snippetLength = 180
    private static let boundaryCharacters = CharacterSet(charactersIn: "。！？；.!?;").union(.newlines)

    private let directoryOverride: URL?
    private let passphraseOverride: String?
    private var key: SymmetricKey?
    private var lastDocument: (identity: Data, snippets: [String])?

    public init(directory: URL? = nil, passphrase: String? = nil) {
        self.directoryOverride = directory
        self.passphraseOverride = passphrase
    }

    public func updateAndFind(
        for documentURL: URL, committedText: String, inlineContext: String
    ) throws -> [String] {
        try Task.checkCancellation()
        let identity = Data(SHA256.hash(data: Data(documentURL.standardizedFileURL.absoluteString.utf8)))
        let current = Self.index(committedText)
        let file = try directory().appendingPathComponent(
            identity.map { String(format: "%02x", $0) }.joined()
        )

        let previous: [String]
        if let lastDocument, lastDocument.identity == identity {
            previous = lastDocument.snippets
        } else if FileManager.default.fileExists(atPath: file.path) {
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
            let data = try AES.GCM.open(sealed, using: encryptionKey(), authenticating: identity)
            previous = try JSONDecoder().decode([String].self, from: data)
        } else {
            previous = []
        }

        // The live editor is authoritative, including after deletions and external edits.
        // Reuse the local index when the bounded text is unchanged.
        let snippets = previous == current ? previous : current
        try Task.checkCancellation()
        if previous != current {
            let encoded = try JSONEncoder().encode(current)
            let sealed = try AES.GCM.seal(encoded, using: encryptionKey(), authenticating: identity)
            guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        lastDocument = (identity, snippets)
        return Self.relevantSnippets(in: snippets, inlineContext: inlineContext)
    }

    public func clear() throws {
        let folder = try directory()
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        lastDocument = nil
        key = nil
        if passphraseOverride == nil {
            try KeychainPassphrase.delete(service: Self.keychainService)
        }
    }

    private func directory() throws -> URL {
        if let directoryOverride { return directoryOverride }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false)
            .appendingPathComponent("KeyType Dev/Document Memory", isDirectory: true)
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let key { return key }
        let secret = try passphraseOverride ?? KeychainPassphrase.loadOrCreate(service: Self.keychainService)
        let newKey = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        key = newKey
        return newKey
    }

    private static func index(_ text: String) -> [String] {
        // Keep the document opening and the most recent completed sentences or lines.
        let opening = completedSnippets(in: String(text.prefix(12_000))).prefix(16)
        let tail = String(text.suffix(12_000))
        let recent = completedSnippets(in: tail, beginsMidDocument: tail != text).suffix(32)
        var seen: Set<String> = []
        return (Array(opening) + recent).filter { seen.insert($0).inserted }
    }

    private static func completedSnippets(in text: String, beginsMidDocument: Bool = false) -> [String] {
        let parts = text.components(separatedBy: boundaryCharacters)
        let completed = parts.dropFirst(beginsMidDocument ? 1 : 0).dropLast()
        return completed.compactMap { part in
            let snippet = String(part.trimmingCharacters(in: .whitespacesAndNewlines).prefix(snippetLength))
            return snippet.count >= 6 ? snippet : nil
        }
    }

    private static func relevantSnippets(in snippets: [String], inlineContext: String) -> [String] {
        // A nearby paragraph can dominate word overlap even if it has nothing to do
        // with the sentence the user is writing.
        let nearby = String(inlineContext.suffix(240)).components(separatedBy: boundaryCharacters)
        guard let currentSentence = nearby.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return [] }
        let query = terms(in: currentSentence)
        guard !query.isEmpty else { return [] }
        var matches: [(snippet: String, score: Int, offset: Int)] = []
        for (offset, snippet) in snippets.enumerated() where !inlineContext.contains(snippet) {
            let score = terms(in: snippet).intersection(query).count
            if score > 0 { matches.append((snippet, score, offset)) }
        }
        return matches.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.offset > rhs.offset : lhs.score > rhs.score
        }.prefix(3).map(\.snippet)
    }

    private static func terms(in text: String) -> Set<String> {
        var result: Set<String> = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) { word, _, _, _ in
            if let word, word.count >= 2 { result.insert(word.lowercased()) }
        }
        return result
    }
}
