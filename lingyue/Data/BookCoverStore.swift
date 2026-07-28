import Foundation
import SwiftUI
import UIKit

/// Disk-backed cover storage keyed by a library book's stable UUID. Covers live in
/// Application Support instead of URLCache so they survive app relaunches and remain
/// attached to the book until that book is removed.
actor BookCoverStore {
    static let shared = BookCoverStore()

    private static let maximumCoverBytes = 20 * 1_024 * 1_024

    private var memory: [UUID: Data] = [:]
    private var inFlight: [UUID: Task<Data?, Never>] = [:]
    private var generations: [UUID: UInt] = [:]
    private let directory: URL

    private init() {
        directory = Self.directoryURL()
    }

    func coverData(for bookID: UUID, remoteURLString: String?) async -> Data? {
        if let data = memory[bookID] {
            return data
        }

        if let data = readFromDisk(bookID: bookID) {
            memory[bookID] = data
            return data
        }

        guard let url = Self.normalizedRemoteURL(from: remoteURLString) else {
            return nil
        }

        let generation = generations[bookID, default: 0]
        if let task = inFlight[bookID] {
            let data = await task.value
            guard generations[bookID, default: 0] == generation else { return nil }
            return data
        }

        let task = Task.detached(priority: .utility) {
            await Self.downloadCover(from: url)
        }
        inFlight[bookID] = task

        let data = await task.value
        guard generations[bookID, default: 0] == generation else { return nil }
        inFlight[bookID] = nil

        guard let data else { return nil }
        memory[bookID] = data
        writeToDisk(data, bookID: bookID)
        return data
    }

    func prefetchCover(for bookID: UUID, remoteURLString: String?) async {
        _ = await coverData(for: bookID, remoteURLString: remoteURLString)
    }

    func removeCover(for bookID: UUID) {
        generations[bookID, default: 0] &+= 1
        inFlight[bookID]?.cancel()
        inFlight[bookID] = nil
        memory[bookID] = nil
        try? FileManager.default.removeItem(at: fileURL(for: bookID))
    }

    func removeOrphanedCovers(keeping activeBookIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files {
            guard file.pathExtension == "cover",
                  let bookID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !activeBookIDs.contains(bookID) else {
                continue
            }
            removeCover(for: bookID)
        }
    }

    private func readFromDisk(bookID: UUID) -> Data? {
        let url = fileURL(for: bookID)
        guard let data = try? Data(contentsOf: url),
              Self.isValidImageData(data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    private func writeToDisk(_ data: Data, bookID: UUID) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(for: bookID), options: [.atomic])
        } catch {
#if DEBUG
            debugLog("[BookCoverStore] write failed: \(error.localizedDescription)")
#endif
        }
    }

    private func fileURL(for bookID: UUID) -> URL {
        directory.appendingPathComponent(bookID.uuidString).appendingPathExtension("cover")
    }

    private static func directoryURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("BookCovers", isDirectory: true)
    }

    private static func normalizedRemoteURL(from string: String?) -> URL? {
        guard let string, var components = URLComponents(string: string) else {
            return nil
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        return components.url
    }

    private static func downloadCover(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  isValidImageData(data) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func isValidImageData(_ data: Data) -> Bool {
        !data.isEmpty
            && data.count <= maximumCoverBytes
            && UIImage(data: data) != nil
    }
}

/// Displays a stored cover immediately after its first successful fetch. A transparent
/// miss lets each caller keep its existing generated-gradient fallback underneath.
struct StoredBookCoverImage: View {
    let bookID: UUID
    let remoteURLString: String?
    var allowsRemoteFetch = true
    var dimOpacity = 0.24

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.black.opacity(dimOpacity))
            } else {
                Color.clear
            }
        }
        .task(id: requestID) {
            let remoteURL = allowsRemoteFetch ? remoteURLString : nil
            let data = await BookCoverStore.shared.coverData(
                for: bookID,
                remoteURLString: remoteURL
            )
            guard !Task.isCancelled else { return }
            image = data.flatMap(UIImage.init(data:))
        }
    }

    private var requestID: String {
        "\(bookID.uuidString)|\(allowsRemoteFetch)|\(remoteURLString ?? "")"
    }
}
