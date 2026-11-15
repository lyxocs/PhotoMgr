import CoreImage
import ImageIO
import Photos
import SwiftUI
import UIKit

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
    @Published private(set) var exportTotal = 0
    @Published private(set) var exportDone = 0
    @Published private(set) var exporting = false
    @Published private(set) var exportMessage = ""

    private let scanner = LibraryScanner()
    private var loaded = false

    var canRead: Bool { status == .authorized || status == .limited }

    func refresh(force: Bool = false) {
        let previous = status
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            days = []
            loaded = false
            return
        }
        guard !scanning, !exporting, force || !loaded || status != previous else { return }
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

    var exportCount: Int {
        days.reduce(0) { count, day in
            count + day.groups.reduce(0) { subtotal, group in
                subtotal + group.assets.filter { selected.contains($0.localIdentifier) }.count
            }
        }
    }

    func exportSelected() {
        guard !exporting, !scanning else { return }
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
        if !selected.insert(id).inserted { selected.remove(id) }
        UserDefaults.standard.set(selected.sorted(), forKey: "selectedPhotoIDs")
    }
}

@MainActor
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var date = Date()
    @State private var filterByDate = false
    @State private var selectedOnly = false
    @State private var confirmingExport = false

    private var visibleDays: [PhotoDay] {
        model.days.compactMap { day in
            if filterByDate {
                guard let dayDate = day.id, Calendar.current.isDate(dayDate, inSameDayAs: date) else { return nil }
            }
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
                    library
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                        Text("允许访问照片后，即可在手机上查找和分组。")
                            .multilineTextAlignment(.center)
                        if model.status == .notDetermined {
                            Button("允许访问照片") { Task { await model.requestAccess() } }
                                .buttonStyle(.borderedProminent)
                        } else if model.status == .denied {
                            Button("打开设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                    .padding(28)
                }
            }
            .navigationTitle("PhotoMgr")
            .toolbar {
                if model.canRead {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("重新扫描", systemImage: "arrow.clockwise") { model.refresh(force: true) }
                            .disabled(model.scanning || model.exporting)
                    }
                }
            }
        }
        .confirmationDialog("保存 \(model.exportCount) 张调色成片？", isPresented: $confirmingExport, titleVisibility: .visible) {
            Button("自动调色并保存") { model.exportSelected() }
        } message: {
            Text("将全部已勾选的照片另存到「PhotoMgr 调色成片」，保留原片。")
        }
        .task { model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh(force: model.status == .limited) }
        }
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

    private var library: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("按日期查找", isOn: $filterByDate)
                    if filterByDate { DatePicker("拍摄日期", selection: $date, displayedComponents: .date) }
                    Toggle("只看已勾选", isOn: $selectedOnly)
                    if model.status == .authorized {
                        Button("自动调色并保存到相册", systemImage: "wand.and.stars") {
                            confirmingExport = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.exportCount == 0 || model.scanning || model.exporting)
                    }
                    if model.exporting {
                        ProgressView(value: Double(model.exportDone), total: Double(model.exportTotal)) {
                            Text("正在调色和保存 · \(model.exportDone) / \(model.exportTotal)")
                        }
                    }
                    if !model.exportMessage.isEmpty {
                        Text(model.exportMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.status == .limited {
                        Text("当前仅显示你授权的照片。保存到相册需要完整访问。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("打开照片权限设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
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
                        Text("\(model.unavailable) 张照片的本地缩略图不可用，暂时单独显示。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if visibleDays.isEmpty && !model.scanning {
                    Text("没有符合条件的照片").foregroundStyle(.secondary)
                }
                ForEach(visibleDays) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        if let date = day.id {
                            Text(date, format: .dateTime.year().month().day()).font(.headline)
                        } else {
                            Text("无拍摄日期").font(.headline)
                        }
                        ForEach(gridGroups(day.groups)) { group in
                            if group.isSimilar && group.assets.count > 1 {
                                Text("相似照片 · \(group.assets.count) 张")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                                ForEach(group.assets, id: \.localIdentifier) { asset in
                                    let checked = model.selected.contains(asset.localIdentifier)
                                    Button { model.toggle(asset.localIdentifier) } label: {
                                        PhotoTile(asset: asset, checked: checked)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(checked ? "取消勾选照片" : "勾选照片")
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

private struct PhotoTile: View {
    let asset: PHAsset
    let checked: Bool
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var generation = UUID()
    private static let manager = PHCachingImageManager()

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear(perform: load)
            .onDisappear {
                generation = UUID()
                if let requestID { Self.manager.cancelImageRequest(requestID) }
            }
    }

    private func load() {
        let token = UUID()
        generation = token
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        requestID = Self.manager.requestImage(
            for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFill, options: options
        ) { result, _ in
            DispatchQueue.main.async {
                if generation == token, let result { image = result }
            }
        }
    }
}
