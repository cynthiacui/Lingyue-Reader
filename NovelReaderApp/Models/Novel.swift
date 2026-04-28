import Foundation
import SwiftUI

struct Novel: Identifiable {
    let id = UUID()
    let title: String
    let author: String
    let genre: String
    let summary: String
    let lastChapter: String
    let progress: Double
    let readMinutes: Int
    let coverColor: Color
    let isFeatured: Bool
}

struct NovelChapter: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let content: String
}

struct NovelCategory: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let symbol: String
    let count: Int
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case paper = "纸张"
    case warm = "暖光"
    case night = "夜读"

    var id: String { rawValue }
}
