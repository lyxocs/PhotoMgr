import CoreImage
import ImageIO
import Photos
import SwiftUI
import UIKit
import Vision

@main
@MainActor
struct PhotoMgrApp: App {
    var body: some Scene {
        WindowGroup { LibraryView() }
    }
}

struct PhotoGroup: Identifiable {
    var assets: [PHAsset]
    var isSimilar = true
    var id: String { assets[0].localIdentifier }
}

struct PhotoDay: Identifiable {
    let id: Date?
    var groups: [PhotoGroup]
}

private struct PhotoSignature {
    let hash: UInt64
    let landscape: Bool

    init?(image: CGImage, asset: PHAsset) {
        var pixels = [UInt8](repeating: 0, count: 72)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return nil }
        var result: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                let offset = row * 9 + column
                result = (result << 1) | (pixels[offset] > pixels[offset + 1] ? 1 : 0)
            }
        }
        hash = result
        landscape = asset.pixelWidth >= asset.pixelHeight
    }

    func matches(_ other: Self) -> Bool {
        landscape == other.landscape && (hash ^ other.hash).nonzeroBitCount <= 10
    }
}

private final class LibraryScanner {
    private let queue = DispatchQueue(label: "PhotoMgr.LibraryScanner", qos: .userInitiated)

    func scan(progress: @escaping (Int, Int) -> Void,
              completion: @escaping ([PhotoDay], Int) -> Void) {
        queue.async {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: .image, options: options)
            let request = PHImageRequestOptions()
            request.isSynchronous = true
            request.isNetworkAccessAllowed = false
            request.resizeMode = .exact
            request.deliveryMode = .fastFormat

            let calendar = Calendar.current
            var days: [Date?: [PhotoGroup]] = [:]
            var currentDay: Date?
            var current: [PHAsset] = []
            var signatures: [PhotoSignature] = []
            var unavailable = 0

            func finishGroup() {
                if !current.isEmpty {
                    days[currentDay, default: []].append(PhotoGroup(assets: current))
                }
                current.removeAll(keepingCapacity: true)
                signatures.removeAll(keepingCapacity: true)
            }

            progress(0, result.count)
            for index in 0..<result.count {
                autoreleasepool {
                    let asset = result.object(at: index)
                    let date = asset.creationDate
                    let day = date.map { calendar.startOfDay(for: $0) }
                    var signature: PhotoSignature?
                    if date != nil {
                        PHImageManager.default().requestImage(
                            for: asset, targetSize: CGSize(width: 96, height: 96),
                            contentMode: .aspectFit, options: request
                        ) { image, _ in
                            if let cgImage = image?.cgImage {
                                signature = PhotoSignature(image: cgImage, asset: asset)
                            }
                        }
                        if signature == nil { unavailable += 1 }
                    }

                    let withinWindow = date.flatMap { end in
                        current.first?.creationDate.map { end.timeIntervalSince($0) <= 12 }
                    } ?? false
                    let matches = signature.map { candidate in
                        signatures.count == current.count && signatures.allSatisfy { candidate.matches($0) }
                    } ?? false
                    if day != currentDay || !withinWindow || !matches || current.count >= 12 {
                        finishGroup()
                        currentDay = day
                    }
                    current.append(asset)
                    if let signature { signatures.append(signature) }
                }
                if index % 50 == 49 || index + 1 == result.count {
                    progress(index + 1, result.count)
                }
            }
            finishGroup()
            let sections = days.map { PhotoDay(id: $0.key, groups: Array($0.value.reversed())) }
                .sorted { ($0.id ?? .distantPast) > ($1.id ?? .distantPast) }
            completion(sections, unavailable)
        }
    }
}

private enum PhotoRanker {
    static func recommend(
        in groups: [PhotoGroup],
        progress: @escaping (Int) -> Void,
        completion: @escaping ([String: String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            var winners: [String: String] = [:]
            for (index, group) in groups.enumerated() {
                var best: (id: String, score: Double)?
                var scored = 0
                for asset in group.assets {
                    autoreleasepool {
                        PHImageManager.default().requestImage(
                            for: asset, targetSize: CGSize(width: 768, height: 768),
                            contentMode: .aspectFit, options: options
                        ) { image, _ in
                            guard let image = image?.cgImage, let score = Self.score(image) else { return }
                            scored += 1
                            if best.map({ score > $0.score }) ?? true {
                                best = (asset.localIdentifier, score)
                            }
                        }
                    }
                }
                if let best, scored == group.assets.count { winners[group.id] = best.id }
                if index % 10 == 9 || index + 1 == groups.count { progress(index + 1) }
            }
            completion(winners)
        }
    }

    private static func score(_ image: CGImage) -> Double? {
        let size = 96
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        var energy = 0.0
        for row in 1..<(size - 1) {
            for col in 1..<(size - 1) {
                let i = row * size + col
                let neighbors = Int(pixels[i - 1]) + Int(pixels[i + 1])
                    + Int(pixels[i - size]) + Int(pixels[i + size])
                let gradient = Double(4 * Int(pixels[i]) - neighbors)
                energy += gradient * gradient
            }
        }
        let sharpness = min(1, log1p(energy / Double((size - 2) * (size - 2))) / 9)
        let mean = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) / 255
        let clipped = Double(pixels.filter { $0 <= 6 || $0 >= 249 }.count) / Double(pixels.count)
        let exposurePenalty = clipped + max(0, abs(mean - 0.5) - 0.17)
        return 0.65 * sharpness - 0.65 * exposurePenalty - closedEyePenalty(in: image)
    }

    private static func closedEyePenalty(in image: CGImage) -> Double {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return 0 }
        for face in request.results ?? [] {
            let width = face.boundingBox.width * CGFloat(image.width)
            let height = face.boundingBox.height * CGFloat(image.height)
            guard face.confidence >= 0.6, width >= 55, height >= 55,
                  let left = eyeOpenness(face.landmarks?.leftEye, width: width, height: height),
                  let right = eyeOpenness(face.landmarks?.rightEye, width: width, height: height)
            else { continue }
            if max(left, right) < 0.17 { return 0.35 }
        }
        return 0
    }

    private static func eyeOpenness(_ eye: VNFaceLandmarkRegion2D?, width: CGFloat, height: CGFloat) -> CGFloat? {
        guard let points = eye?.normalizedPoints, points.count >= 4 else { return nil }
        let scaled = points.map { CGPoint(x: $0.x * width, y: $0.y * height) }
        var axis = CGPoint.zero
        var diameter: CGFloat = 0
        for (index, point) in scaled.enumerated() {
            for other in scaled.dropFirst(index + 1) {
                let dx = other.x - point.x
                let dy = other.y - point.y
                let distance = hypot(dx, dy)
                if distance > diameter {
                    diameter = distance
                    axis = CGPoint(x: dx, y: dy)
                }
            }
        }
        guard diameter >= 8 else { return nil }
        let perpendicular = scaled.map { ($0.y * axis.x - $0.x * axis.y) / diameter }
        guard let low = perpendicular.min(), let high = perpendicular.max() else { return nil }
        return (high - low) / diameter
    }
}

private enum AlbumExporter {
    static let title = "PhotoMgr 调色成片"
    private static let albumKey = "gradedAlbumIdentifier"
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let toneFilters: Set<String> = [
        "CIColorControls", "CIVibrance", "CIToneCurve", "CIHighlightShadowAdjust", "CIExposureAdjust"
    ]

    enum ExportError: Error {
        case libraryAccess, imageUnavailable, encodingFailed, albumUnavailable
    }

    static func export(
        _ assets: [PHAsset],
        progress: @escaping (Int) -> Void,
        completion: @escaping (Int, Int) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var saved = 0
            for (index, asset) in assets.enumerated() {
                autoreleasepool {
                    do {
                        try save(asset)
                        saved += 1
                    } catch {
                        // Continue the batch when an individual photo cannot be read or saved.
                    }
                }
                progress(index + 1)
            }
            completion(saved, assets.count - saved)
        }
    }

    private static func save(_ asset: PHAsset) throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw ExportError.libraryAccess
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        var image: CIImage?
        var readError: Error?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
            data, _, orientation, info in
            readError = info?[PHImageErrorKey] as? Error
            if let data, let decoded = CIImage(data: data) {
                image = decoded.oriented(orientation)
            }
        }
        guard let image else { throw readError ?? ExportError.imageUnavailable }

        let adjusted = image.autoAdjustmentFilters().reduce(image) { input, filter in
            guard toneFilters.contains(filter.name) else { return input }
            filter.setValue(input, forKey: kCIInputImageKey)
            return filter.outputImage ?? input
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let jpeg = context.jpegRepresentation(
            of: adjusted, colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.94]
        ) else { throw ExportError.encodingFailed }

        let defaults = UserDefaults.standard
        let album = defaults.string(forKey: albumKey).flatMap {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject
        }
        var createdAlbumID: String?
        var added = false
        try PHPhotoLibrary.shared().performChangesAndWait {
            let albumRequest: PHAssetCollectionChangeRequest
            if let album {
                guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
                albumRequest = request
            } else {
                albumRequest = .creationRequestForAssetCollection(withTitle: title)
                createdAlbumID = albumRequest.placeholderForCreatedAssetCollection.localIdentifier
            }

            let creation = PHAssetCreationRequest.forAsset()
            creation.creationDate = asset.creationDate
            creation.addResource(with: .photo, data: jpeg, options: nil)
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            albumRequest.addAssets([placeholder] as NSArray)
            added = true
        }
        guard added else { throw ExportError.albumUnavailable }
        if let createdAlbumID { defaults.set(createdAlbumID, forKey: albumKey) }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var days: [PhotoDay] = []
    @Published private(set) var selected = Set(UserDefaults.standard.stringArray(forKey: "selectedPhotoIDs") ?? [])
    @Published private(set) var scanning = false
    @Published private(set) var progress = 0
    @Published private(set) var total = 0
    @Published private(set) var unavailable = 0
    @Published private(set) var recommendations = Set(UserDefaults.standard.stringArray(forKey: "recommendedPhotoIDs") ?? [])
    @Published private(set) var ranking = false
    @Published private(set) var rankedGroups = 0
    @Published private(set) var rankingTotal = 0
    @Published private(set) var rankingMessage = ""
    @Published private(set) var exportTotal = 0
    @Published private(set) var exportDone = 0
    @Published private(set) var exporting = false
    @Published private(set) var exportMessage = ""

    private let scanner = LibraryScanner()
    private var manualIDs = Set(UserDefaults.standard.stringArray(forKey: "manualSelectionIDs")
                                ?? UserDefaults.standard.stringArray(forKey: "selectedPhotoIDs") ?? [])
    private var loaded = false
    private var availableIDs: Set<String> = []

    var canRead: Bool { status == .authorized || status == .limited }

    func refresh(force: Bool = false) {
        let previous = status
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            days = []
            availableIDs = []
            loaded = false
            return
        }
        guard !scanning, !exporting, !ranking, force || !loaded || status != previous else { return }
        scanning = true
        progress = 0
        total = 0
        scanner.scan { [weak self] done, total in
            DispatchQueue.main.async {
                self?.progress = done
                self?.total = total
            }
        } completion: { [weak self] days, unavailable in
            DispatchQueue.main.async {
                guard let self else { return }
                let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                let accessChanged = current != self.status
                self.scanning = false
                if accessChanged || !self.canRead {
                    self.refresh(force: true)
                    return
                }
                self.availableIDs = Set(days.flatMap(\.groups).flatMap(\.assets).map(\.localIdentifier))
                self.days = days
                self.unavailable = unavailable
                self.loaded = true
            }
        }
    }

    func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh(force: true)
    }

    var exportCount: Int { selected.intersection(availableIDs).count }

    var canRank: Bool {
        !scanning && !exporting && !ranking && days.contains { day in
            day.groups.contains { $0.assets.count > 1 }
        }
    }

    func rankGroups() {
        guard canRank else { return }
        let groups = days.flatMap(\.groups).filter { $0.assets.count > 1 }
        ranking = true
        rankedGroups = 0
        rankingTotal = groups.count
        rankingMessage = ""
        PhotoRanker.recommend(in: groups) { [weak self] done in
            DispatchQueue.main.async { self?.rankedGroups = done }
        } completion: { [weak self] winners in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ranking = false
                guard self.canRead else { return }
                let accessible = Set(groups.filter { group in
                    group.assets.allSatisfy { self.availableIDs.contains($0.localIdentifier) }
                }.map(\.id))
                let visibleWinners = winners.filter { accessible.contains($0.key) }
                var updated = self.selected
                for group in groups {
                    guard let winner = visibleWinners[group.id] else { continue }
                    let ids = group.assets.map(\.localIdentifier)
                    if self.manualIDs.isDisjoint(with: ids) {
                        updated.subtract(ids)
                        updated.insert(winner)
                    }
                }
                self.selected = updated
                self.recommendations = Set(visibleWinners.values)
                self.saveSelections()
                UserDefaults.standard.set(self.recommendations.sorted(), forKey: "recommendedPhotoIDs")
                let missed = groups.count - visibleWinners.count
                self.rankingMessage = missed == 0
                    ? "已推荐 \(visibleWinners.count) 组"
                    : "已推荐 \(visibleWinners.count) 组，\(missed) 组无法读取"
            }
        }
    }

    func exportSelected() {
        guard !exporting, !scanning, !ranking else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            exportMessage = "请在设置中为 PhotoMgr 开启照片完整访问，然后重试。"
            return
        }

        let assets = days.flatMap(\.groups).flatMap(\.assets)
            .filter { selected.contains($0.localIdentifier) }
        guard !assets.isEmpty else { return }
        exporting = true
        exportDone = 0
        exportTotal = assets.count
        exportMessage = ""
        AlbumExporter.export(assets) { [weak self] done in
            DispatchQueue.main.async { self?.exportDone = done }
        } completion: { [weak self] saved, failed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                self.exportMessage = failed == 0
                    ? "已保存 \(saved) 张到「\(AlbumExporter.title)」。"
                    : "已保存 \(saved) 张，\(failed) 张未能读取或保存。"
            }
        }
    }

    func toggle(_ id: String) {
        setSelected([id], to: !selected.contains(id))
    }

    func setSelected(_ ids: [String], to checked: Bool) {
        manualIDs.formUnion(ids)
        if checked {
            selected.formUnion(ids)
        } else {
            selected.subtract(ids)
        }
        saveSelections()
    }

    func replaceSelection(in group: PhotoGroup, with id: String) {
        let ids = group.assets.map(\.localIdentifier)
        manualIDs.formUnion(ids)
        selected.subtract(ids)
        selected.insert(id)
        saveSelections()
    }

    private func saveSelections() {
        UserDefaults.standard.set(selected.sorted(), forKey: "selectedPhotoIDs")
        UserDefaults.standard.set(manualIDs.sorted(), forKey: "manualSelectionIDs")
    }
}

@MainActor
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var date: Date?
    @State private var selectedOnly = false
    @State private var choosingDate = false
    @State private var confirmingExport = false
    @State private var preview: PreviewSelection?

    private var visibleDays: [PhotoDay] {
        model.days.compactMap { day in
            if let date, day.id != date { return nil }
            guard selectedOnly else { return day }
            let groups = day.groups.compactMap { group -> PhotoGroup? in
                let assets = group.assets.filter { model.selected.contains($0.localIdentifier) }
                return assets.isEmpty ? nil : PhotoGroup(assets: assets)
            }
            return groups.isEmpty ? nil : PhotoDay(id: day.id, groups: groups)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.canRead {
                    library.safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
                } else {
                    ContentUnavailableView {
                        Label("访问照片", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("允许访问后，即可按日期查找照片并浏览相似组。")
                    } actions: {
                        if model.status == .notDetermined {
                            Button("允许访问照片") { Task { await model.requestAccess() } }
                                .buttonStyle(.borderedProminent)
                        } else if model.status == .denied {
                            Button("打开设置", action: openSettings).buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("PhotoMgr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.canRead {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("重新扫描", systemImage: "arrow.clockwise") { model.refresh(force: true) }
                            .disabled(model.scanning || model.exporting || model.ranking)
                    }
                }
            }
        }
        .tint(Color(uiColor: .systemTeal))
        .sheet(isPresented: $choosingDate) { datePicker }
        .fullScreenCover(item: $preview) { selection in
            PhotoPreview(model: model, selection: selection)
        }
        .confirmationDialog("保存 \(model.exportCount) 张调色成片？",
                            isPresented: $confirmingExport, titleVisibility: .visible) {
            Button("自动调色并保存") { model.exportSelected() }
        } message: {
            Text("将全部已勾选的照片另存到「PhotoMgr 调色成片」，包括当前筛选隐藏的照片。原片保留。")
        }
        .task { model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refresh(force: model.status == .limited)
                if !model.canRead { preview = nil }
            }
        }
    }

    private var library: some View {
        let days = visibleDays
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                filters
                libraryStatus
                if days.isEmpty && !model.scanning {
                    ContentUnavailableView(selectedOnly ? "没有已勾选的照片" : "没有照片",
                                           systemImage: selectedOnly ? "checkmark.circle" : "photo.on.rectangle")
                }
                ForEach(days) { day in
                    Section {
                        ForEach(gridGroups(day.groups)) { group in
                            groupGrid(group)
                        }
                    } header: {
                        dayHeader(day)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("照片筛选", selection: $selectedOnly) {
                Text("全部照片").tag(false)
                Text("已勾选").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("自动选片", systemImage: "wand.and.stars") { model.rankGroups() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRank)
                Button { choosingDate = true } label: {
                    Label {
                        if let date {
                            Text(date, format: .dateTime.year().month().day())
                        } else {
                            Text("按日期查找")
                        }
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.days.isEmpty)

                if date != nil {
                    Button("清除日期筛选", systemImage: "xmark.circle.fill") { date = nil }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .padding(.top, 10)
    }

    private var datePicker: some View {
        NavigationStack {
            List {
                Button("所有日期") { applyDate(nil) }
                ForEach(model.days.compactMap(\.id), id: \.self) { day in
                    Button { applyDate(day) } label: {
                        HStack {
                            Text(day, format: .dateTime.year().month().day())
                            Spacer()
                            if day == date { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("拍摄日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { choosingDate = false }
                }
            }
        }
    }

    @ViewBuilder
    private var libraryStatus: some View {
        if model.status == .limited {
            VStack(alignment: .leading, spacing: 6) {
                Text("当前仅显示你授权的照片。相册导出需要完整访问。")
                Button("打开照片权限设置", action: openSettings)
            }
            .font(.subheadline)
        }
        if model.ranking {
            ProgressView(value: Double(model.rankedGroups), total: Double(model.rankingTotal)) {
                Text("正在自动选片 · \(model.rankedGroups) / \(model.rankingTotal) 组")
            }
        } else if !model.rankingMessage.isEmpty {
            Text(model.rankingMessage).font(.footnote).foregroundStyle(.secondary)
        }
        if model.scanning {
            if model.total > 0 {
                ProgressView(value: Double(model.progress), total: Double(model.total)) {
                    Text("正在分组 · \(model.progress) / \(model.total)")
                }
            } else {
                ProgressView("正在读取相册")
            }
        } else if model.unavailable > 0 {
            Text("\(model.unavailable) 张照片暂时单独显示，因为本地缩略图不可用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.exporting {
                ProgressView(value: Double(model.exportDone), total: Double(model.exportTotal)) {
                    Text("正在调色和保存 · \(model.exportDone) / \(model.exportTotal)")
                        .monospacedDigit()
                }
                .accessibilityLabel("导出进度")
            } else if !model.exportMessage.isEmpty {
                Text(model.exportMessage).font(.footnote)
            }
            ViewThatFits(in: .horizontal) {
                HStack { selectionCount; Spacer(minLength: 16); exportButton }
                VStack(alignment: .leading, spacing: 8) { selectionCount; exportButton }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectionCount: some View {
        Text("已勾选 \(model.exportCount) 张")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
    }

    @ViewBuilder
    private var exportButton: some View {
        if model.status == .authorized {
            Button("调色并保存", systemImage: "wand.and.stars") { confirmingExport = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.exportCount == 0 || model.scanning || model.exporting || model.ranking)
                .accessibilityLabel("自动调色并保存到相册")
        }
    }

    private func dayHeader(_ day: PhotoDay) -> some View {
        HStack {
            if let date = day.id {
                Text(date, format: .dateTime.year().month().day()).font(.headline)
            } else {
                Text("无拍摄日期").font(.headline)
            }
            Spacer()
            Text("\(day.groups.reduce(0) { $0 + $1.assets.count }) 张")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityAddTraits(.isHeader)
    }

    private func groupGrid(_ group: PhotoGroup) -> some View {
        let similar = group.isSimilar && group.assets.count > 1
        let ids = group.assets.map(\.localIdentifier)
        let allChecked = ids.allSatisfy(model.selected.contains)
        return VStack(alignment: .leading, spacing: 6) {
            if similar {
                HStack {
                    Label("相似照片 · \(ids.count) 张", systemImage: "square.stack")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !selectedOnly {
                        Button(allChecked ? "取消整组" : "勾选整组") {
                            model.setSelected(ids, to: !allChecked)
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 7)], spacing: 7) {
                ForEach(group.assets, id: \.localIdentifier) { asset in
                    let checked = model.selected.contains(asset.localIdentifier)
                    ZStack(alignment: .topTrailing) {
                        Button {
                            preview = PreviewSelection(assets: similar ? group.assets : [asset], current: asset.localIdentifier)
                        } label: {
                            AssetImage(asset: asset, thumbnail: true)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.recommendations.contains(asset.localIdentifier)
                                            ? "查看推荐照片" : "查看照片")
                        .contextMenu {
                            if similar && !selectedOnly {
                                Button("只选组内这张", systemImage: "checkmark.circle") {
                                    model.replaceSelection(in: group, with: asset.localIdentifier)
                                }
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if model.recommendations.contains(asset.localIdentifier) {
                                Label("推荐", systemImage: "star.fill")
                                    .font(.caption2.weight(.semibold))
                                    .padding(4)
                                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .accessibilityHidden(true)
                            }
                        }

                        Button { model.toggle(asset.localIdentifier) } label: {
                            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(checked ? Color(uiColor: .systemTeal) : .white)
                                .padding(4)
                                .background(.black.opacity(0.58), in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(checked ? "取消勾选照片" : "勾选照片")
                        .accessibilityAddTraits(checked ? .isSelected : [])
                    }
                }
            }
        }
        .padding(similar ? 8 : 0)
        .background(similar ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func gridGroups(_ groups: [PhotoGroup]) -> [PhotoGroup] {
        var result: [PhotoGroup] = []
        var singles: [PHAsset] = []
        for group in groups {
            if group.assets.count == 1 {
                singles.append(group.assets[0])
            } else {
                if !singles.isEmpty {
                    result.append(PhotoGroup(assets: singles, isSimilar: false))
                    singles.removeAll(keepingCapacity: true)
                }
                result.append(group)
            }
        }
        if !singles.isEmpty { result.append(PhotoGroup(assets: singles, isSimilar: false)) }
        return result
    }

    private func applyDate(_ day: Date?) {
        date = day
        choosingDate = false
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct PreviewSelection: Identifiable {
    let assets: [PHAsset]
    let current: String
    var id: String { current }
}

@MainActor
private struct PhotoPreview: View {
    @ObservedObject var model: LibraryModel
    let selection: PreviewSelection
    @Environment(\.dismiss) private var dismiss
    @State private var current: String

    init(model: LibraryModel, selection: PreviewSelection) {
        self.model = model
        self.selection = selection
        _current = State(initialValue: selection.current)
    }

    var body: some View {
        let position = selection.assets.firstIndex { $0.localIdentifier == current } ?? 0
        let checked = model.selected.contains(current)
        VStack(spacing: 0) {
            HStack {
                Button("完成") { dismiss() }
                Spacer()
                Text("\(position + 1) / \(selection.assets.count)").monospacedDigit()
                Spacer()
                Button(checked ? "取消勾选" : "勾选", systemImage: checked ? "checkmark.circle.fill" : "circle") {
                    model.toggle(current)
                }
            }
            .padding(16)
            TabView(selection: $current) {
                ForEach(selection.assets, id: \.localIdentifier) { asset in
                    AssetImage(asset: asset, thumbnail: false).tag(asset.localIdentifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

private struct AssetImage: View {
    let asset: PHAsset
    let thumbnail: Bool
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var generation = UUID()
    @State private var unavailable = false
    private static let manager = PHCachingImageManager()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                thumbnail ? Color(uiColor: .tertiarySystemFill) : .black
                if let image {
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: thumbnail ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if unavailable {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary)
                        .accessibilityLabel("照片暂时无法读取")
                } else if !thumbnail {
                    ProgressView()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            generation = UUID()
            if let requestID { Self.manager.cancelImageRequest(requestID) }
            image = nil
        }
    }

    private func load() {
        let token = UUID()
        generation = token
        unavailable = false
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        let dimension: CGFloat = thumbnail ? 360 : 1800
        requestID = Self.manager.requestImage(
            for: asset, targetSize: CGSize(width: dimension, height: dimension),
            contentMode: thumbnail ? .aspectFill : .aspectFit, options: options
        ) { result, info in
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
            DispatchQueue.main.async {
                guard generation == token else { return }
                if let result {
                    image = result
                } else if !degraded && image == nil {
                    unavailable = true
                }
            }
        }
    }
}
