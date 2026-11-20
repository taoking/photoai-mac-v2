import AppKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=analysis`：M6 后台分析与搜索（计划 · M6 验收）。准备工作见 `Scripts/test/m6-analysis-test.sh`。
///
/// 库的副本里分析状态全是“待做”：先看 OCR、人物在后台开始，暂停后不再前进、设置记住，继续后接着做；
/// 等全部做完，再按 OCR 的一行字、月份（`2026-08` 是日期不是编号）、编号范围、人名搜索，核对结果，
/// 给人物命名、“不是 TA”、删搜索条件；最后移除卷，照片全部隐藏后什么都搜不到。
/// 不需要卡插着（分析用本机预览）。只对库的副本用。
extension ScenarioRunner {
    func buildAnalysis() {
        var ocrDoneAtPause = 0
        var textPhoto: PhotoID?
        var textLine = ""
        var personID: PersonID?
        var personPhotos: [PhotoID] = []

        func counts(_ kind: AnalysisKind) -> AnalysisCounts { (try? model.reader?.analysisCounts(kind)) ?? AnalysisCounts() }
        func search(_ text: String) {
            model.searchText = text
            model.submitSearch()
        }
        func resultCaptureDates() -> [String] { model.resultIDs.compactMap { model.photo($0)?.captureDate } }

        wait("照片读好", timeout: 30) { [self] in model.photoCount > 0 }
        wait("OCR、人物在后台开始", timeout: 20) { [self] in
            model.analysisRunning.contains(.ocr) && (model.analysisRunning.contains(.faces) || model.faceModelMissing)
        }
        step("状态栏") { [self] in
            check(!model.faceModelMissing, "人脸识别模型已装（Scripts/install-face-model.sh）")
            check(model.analysisStatus(.ocr) != nil, "状态栏显示 OCR 进度：\(model.analysisStatus(.ocr) ?? "")")
            check(model.analysisStatus(.faces) != nil, "状态栏显示人物进度：\(model.analysisStatus(.faces) ?? "")")
            snapshot("m6-running")
        }
        step("暂停 OCR") { [self] in
            model.toggleAnalysisPause(.ocr)
            check(AnalysisSettings.paused.contains(.ocr), "暂停记在本机设置里（重启后仍然暂停）")
        }
        wait("OCR 停下", timeout: 10) { [self] in !model.analysisRunning.contains(.ocr) }
        asyncStep("暂停期间") { [self] done in
            ocrDoneAtPause = counts(.ocr).done
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                MainActor.assumeIsolated {
                    let now = counts(.ocr)
                    check(now.done == ocrDoneAtPause && now.pending > 0, "暂停 3 秒，OCR 没有前进（\(now.done) 张已做、\(now.pending) 张待做）")
                    check(model.analysisStatus(.ocr)?.contains("已暂停") == true, "状态栏写着“\(model.analysisStatus(.ocr) ?? "")”")
                    model.toggleAnalysisPause(.ocr)
                    done()
                }
            }
        }
        wait("继续后接着做", timeout: 20) { counts(.ocr).done > ocrDoneAtPause }
        step("续跑") { [self] in
            check(!AnalysisSettings.paused.contains(.ocr), "继续后设置里不再记着暂停")
            check(counts(.ocr).done > ocrDoneAtPause, "从没做的接着做：\(ocrDoneAtPause) → \(counts(.ocr).done) 张")
        }
        wait("人物识别做完", timeout: 300) { [self] in !model.analysisRunning.contains(.faces) && counts(.faces).pending == 0 }
        wait("OCR 做完", timeout: 900) { [self] in !model.analysisRunning.contains(.ocr) && counts(.ocr).pending == 0 }
        wait("人物网格读好", timeout: 10) { [self] in !model.people.isEmpty }
        step("分析结果") { [self] in
            let ocr = counts(.ocr), faces = counts(.faces)
            check(ocr.pending == 0 && ocr.failed == 0, "OCR \(ocr.done) 张全部做完，失败 \(ocr.failed)")
            check(faces.pending == 0 && faces.failed == 0, "人物 \(faces.done) 张全部做完，失败 \(faces.failed)")
            check(model.analysisStatus(.ocr) == nil && model.analysisStatus(.faces) == nil, "做完后状态栏不再显示")
            print("  人物：\(model.people.count) 个，前几个各 \(model.people.prefix(6).map(\.photoCount)) 张")
            // 找一张 OCR 出两个汉字以上的照片，用它的一行字搜。
            for id in model.resultIDs {
                guard let text = try? model.reader?.ocrText(of: id) else { continue }
                if let line = text.split(separator: "\n").map(String.init).first(where: { $0.filter(\.isLetter).count >= 3 }) {
                    textPhoto = id
                    textLine = line
                    break
                }
            }
            check(textPhoto != nil, "有照片认出了文字：“\(textLine)”")
            model.selection = .people
        }
        asyncStep("人物网格") { [self] done in
            // 封面从预览里裁，等它们画出来。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                MainActor.assumeIsolated {
                    snapshot("m6-people")
                    search("\"\(textLine)\"")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { done() }
                }
            }
        }
        step("OCR 搜索结果") { [self] in
            guard let textPhoto else { return }
            check(model.resultIDs.contains(textPhoto), "搜“\(textLine)”找到那张照片（共 \(model.resultIDs.count) 张）")
            let unrelated = model.resultIDs.filter { id in
                let text = ((try? model.reader?.ocrText(of: id)) ?? nil) ?? ""
                let name = model.photo(id)?.baseName ?? ""
                return !text.localizedCaseInsensitiveContains(textLine) && !name.localizedCaseInsensitiveContains(textLine)
            }
            check(unrelated.isEmpty, "结果里没有无关的照片（文字或文件名里都有这段字）")
            snapshot("m6-search-text")
        }
        step("⌘F 聚焦搜索框") { [self] in
            model.selection = .all
            press("f", keyCode: 3, flags: .command)
        }
        step("搜索框里打字") { [self] in
            let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            check(window?.firstResponder is NSText, "⌘F 后焦点在搜索框")
            let focused = model.focusedPhotoID.flatMap { model.photo($0) }
            press("5", keyCode: 23)
            check(model.searchText == "5", "在搜索框里按 5 是输入文字（搜索框里现在是“\(model.searchText)”）")
            check(model.focusedPhotoID.flatMap { model.photo($0) }?.rating == focused?.rating, "按 5 没有给照片打星")
            model.searchText = ""
            window?.makeFirstResponder(nil)
        }
        step("搜月份 2026-08") { search("2026-08") }
        step("月份结果") { [self] in
            guard case .search(let query) = model.selection else { return check(false, "切到搜索结果") }
            check(query.terms == [.datePrefix("2026-08")], "2026-08 认成日期（标签“\(query.terms.first?.title ?? "")”），不是编号范围")
            let expected = (try? model.reader?.photos(in: .datePrefix("2026-08")).count) ?? -1
            let dates = resultCaptureDates()
            check(model.resultIDs.count == expected && expected > 0, "结果 \(model.resultIDs.count) 张，和侧栏 2026 年 8 月的张数一样（\(expected)）")
            check(dates.allSatisfy { $0.hasPrefix("2026-08") }, "结果都是 2026 年 8 月拍的")
        }
        step("编号范围 1035-1039") { search("1035-1039") }
        step("编号结果") { [self] in
            let numbers = model.resultIDs.compactMap { model.photo($0)?.baseName }.compactMap { PhotoIdentity.fileNumber(ofBaseName: $0) }
            check(!numbers.isEmpty && numbers.allSatisfy { (1035...1039).contains($0) }, "结果都在编号 1035–1039 里：\(numbers.sorted())")
        }
        step("给最大的人物命名") { [self] in
            guard let person = model.people.first(where: { $0.name == nil }) else { return check(false, "有未命名的人物") }
            personID = person.id
            personPhotos = (try? model.reader?.photos(in: .person(person.id)).map(\.id)) ?? []
            check(personPhotos.count == person.photoCount, "人物网格里的张数（\(person.photoCount)）和 TA 的照片数一样")
            model.renamePerson(person.id, to: "测试人物甲")
        }
        wait("名字进了搜索词表", timeout: 5) { [self] in model.vocabulary.people["测试人物甲"] != nil }
        step("按人名搜") { search("测试人物甲") }
        step("人名搜索结果") { [self] in
            guard case .search(let query) = model.selection else { return check(false, "切到搜索结果") }
            check(query.terms == [.person(personID ?? -1, name: "测试人物甲")], "认成人物（标签“\(query.terms.first?.title ?? "")”）")
            check(Set(model.resultIDs) == Set(personPhotos), "搜到 TA 的全部 \(personPhotos.count) 张，没有别人")
            snapshot("m6-search-person")
        }
        step("人名 + 月份") { search("测试人物甲 2026-08") }
        step("条件取“并且”，删掉一个条件") { [self] in
            let both = Set(model.resultIDs)
            let expected = Set(personPhotos).intersection(Set((try? model.reader?.photos(in: .datePrefix("2026-08")).map(\.id)) ?? []))
            check(both == expected, "人名并且月份：\(both.count) 张")
            model.removeSearchTerm(at: 1)
        }
        step("删掉月份以后") { [self] in
            check(Set(model.resultIDs) == Set(personPhotos), "只剩人名：\(model.resultIDs.count) 张")
            model.selection = .person(personID ?? -1)
        }
        step("“不是 TA”") { [self] in
            guard let last = model.resultIDs.last else { return check(false, "人物页有照片") }
            check(model.sourceTitle == "测试人物甲", "人物页标题是名字")
            model.selectedPhotoIDs = [last]
            model.removeSelectionFromPerson()
            personPhotos.removeAll { $0 == last }
        }
        wait("人物页刷新", timeout: 5) { [self] in model.resultIDs.count == personPhotos.count }
        step("拿出来以后") { [self] in
            check(Set(model.resultIDs) == Set(personPhotos), "拿出来的照片不在 TA 的页面里了（\(personPhotos.count) 张）")
            check(model.people.first { $0.id == personID }?.photoCount == personPhotos.count, "人物网格里的张数跟着变")
            snapshot("m6-person")
        }
        step("移除卷，照片全部隐藏") { [self] in
            guard let library = model.library else { return }
            for volume in model.volumes { try? library.removeVolume(volume.id); model.volumeWasRemoved(volume.id) }
            model.reloadSidebar()
            search("\"\(textLine)\"")
        }
        step("隐藏照片不被搜到") { [self] in
            check(model.resultIDs.isEmpty, "OCR 那一行搜不到了（\(model.resultIDs.count) 张）")
            search("测试人物甲")
        }
        step("隐藏照片不被搜到（人名）") { [self] in
            check(model.resultIDs.isEmpty, "人名也搜不到（\(model.resultIDs.count) 张）")
        }
    }
}
