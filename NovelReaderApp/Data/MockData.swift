import SwiftUI

enum MockData {
    static let novels: [Novel] = [
        Novel(
            title: "长安夜行录",
            author: "顾微澜",
            genre: "历史奇幻",
            summary: "灯火初上的长安城里，女史沈砚循着一页残卷，追查牵动朝局的旧案。",
            lastChapter: "第 48 章 玄武门外",
            progress: 0.72,
            readMinutes: 326,
            coverColor: .readerIndigo,
            isFeatured: true
        ),
        Novel(
            title: "雾海听潮",
            author: "林听白",
            genre: "都市悬疑",
            summary: "失眠电台主播收到来自十年前的留言，每一段潮声都指向一座消失的海边小城。",
            lastChapter: "第 21 章 旧磁带",
            progress: 0.38,
            readMinutes: 142,
            coverColor: .readerTeal,
            isFeatured: true
        ),
        Novel(
            title: "山月不知心底事",
            author: "南枝",
            genre: "现代言情",
            summary: "重逢并不总是答案。两个在山城长大的少年，终于学会把遗憾写成新的开始。",
            lastChapter: "第 64 章 春雨",
            progress: 0.91,
            readMinutes: 481,
            coverColor: .readerRose,
            isFeatured: false
        ),
        Novel(
            title: "星河算法",
            author: "陈既明",
            genre: "科幻",
            summary: "当城市由预测模型接管，年轻工程师发现最准确的算法，正在悄悄删除人的选择。",
            lastChapter: "第 17 章 沙盒城市",
            progress: 0.24,
            readMinutes: 95,
            coverColor: .readerBlue,
            isFeatured: true
        ),
        Novel(
            title: "一碗人间烟火",
            author: "苏小满",
            genre: "治愈生活",
            summary: "深夜食堂的新掌柜用一碗面、一盏灯，收留城市里无处安放的心事。",
            lastChapter: "第 35 章 桂花糖藕",
            progress: 0.56,
            readMinutes: 233,
            coverColor: .readerAmber,
            isFeatured: false
        )
    ]

    static let categories: [NovelCategory] = [
        NovelCategory(name: "古风", symbol: "scroll", count: 128),
        NovelCategory(name: "悬疑", symbol: "magnifyingglass", count: 94),
        NovelCategory(name: "科幻", symbol: "atom", count: 76),
        NovelCategory(name: "言情", symbol: "heart", count: 156),
        NovelCategory(name: "治愈", symbol: "leaf", count: 63)
    ]

    static var currentlyReading: [Novel] {
        novels.filter { $0.progress > 0.3 }.prefix(3).map { $0 }
    }

    static var featuredNovels: [Novel] {
        novels.filter(\.isFeatured)
    }

    static var trendingNovels: [Novel] {
        novels.sorted { $0.readMinutes > $1.readMinutes }
    }

    static func chapters(for novel: Novel) -> [NovelChapter] {
        switch novel.title {
        case "长安夜行录":
            return longChapters(
                titles: ["雨入长安", "残卷", "坊门夜鼓", "青帷马车", "旧案名册", "太常寺灯", "朱印", "暗巷", "更漏声", "宫墙影", "雪夜供词", "玄武门外", "金吾卫", "旧人归来", "天明之前"],
                seed: "沈砚循着残卷在长安夜色中追查旧案。雨声落在青石板上，灯火照见被岁月掩住的名字。她越接近真相，越发现当年的沉默并非遗忘，而是一张仍在收紧的网。"
            )
        case "雾海听潮":
            return longChapters(
                titles: ["午夜来信", "旧磁带", "雾港坐标", "灯塔", "退潮之后"],
                seed: "电台午夜只剩潮声，林舟却在杂音里听见失踪姐姐的留言。每一卷旧磁带都指向海雾深处，那座从地图上消失的小城，似乎仍在某个夜晚等待归人。"
            )
        case "山月不知心底事":
            return longChapters(
                titles: ["山城旧雨", "桂花巷", "旧书店", "未寄出的信", "春雨"],
                seed: "许知夏与周叙在山城重逢。雨声、旧巷、热栗子和没有寄出的信，把七年的沉默一点点拆开。遗憾不能重写，但人可以学着重新靠近。"
            )
        case "星河算法":
            return longChapters(
                titles: ["沙盒城市", "零号样本", "异常预测", "第七区", "人的选择"],
                seed: "城市醒来之前，算法已经替每个人安排好路线。程砚曾相信预测系统能减少痛苦，直到它开始删除那些不符合最优解的人。"
            )
        case "一碗人间烟火":
            return longChapters(
                titles: ["深夜面馆", "桂花糖藕", "一盏灯", "热汤", "明天再想"],
                seed: "梧桐巷的面馆总在深夜亮着灯。苏禾不急着追问每位客人的来处，只把热汤端上桌，让漂泊的心事先有地方坐下。"
            )
        default:
            return longChapters(
                titles: ["第一章", "第二章", "第三章"],
                seed: "夜色安静下来，故事从这里开始。纸页翻动的声音很轻，却足以把人带到另一个世界。"
            )
        }
    }

    private static func longChapters(titles: [String], seed: String) -> [NovelChapter] {
        titles.enumerated().map { index, title in
            NovelChapter(
                title: "第 \(index + 1) 章 \(title)",
                content: longChapterContent(seed: seed, chapterNumber: index + 1)
            )
        }
    }

    private static func longChapterContent(seed: String, chapterNumber: Int) -> String {
        [
            "\(seed)\n\n第 \(chapterNumber) 章开始时，窗外的光线还很低，人物的脚步声在安静里显得格外清楚。那些被暂时按下的疑问又浮上来，像纸页背面的墨痕，越是不看，越能感觉到它存在。",
            "他停下来，重新整理眼前的线索。每一个名字、每一句没有说完的话、每一次迟疑，都像被放进同一只匣子里。匣子并不沉，却让人很难轻易放下。",
            "街角传来细碎的人声，风把远处的灯影推到墙上。有人从身边经过，又很快消失在另一条巷子里。故事里的城市并不喧哗，却始终有人在暗处等待一个回答。",
            "这一刻，主角忽然意识到，真正重要的并不是谜底本身，而是一路追问时看见的那些人。有人隐瞒，是因为害怕；有人离开，是因为不敢回头；也有人留下，只是想证明一切还来得及。",
            "夜色渐深，纸页上的字仿佛慢慢有了温度。主角把那句话读了第二遍，终于明白其中藏着的不是威胁，而是一种近乎笨拙的提醒。",
            "等到风停下来，屋里只剩下呼吸和灯火。下一步该往哪里去，似乎已经不需要别人指引。门外仍有未解的事，但至少此刻，心里有了一点可以握住的光。"
        ].joined(separator: "\n\n")
    }
}
