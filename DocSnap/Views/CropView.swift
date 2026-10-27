import SwiftUI

/// Drag the four corners (or the edges) to fit the paper. A loupe magnifies the corner being dragged.
struct CropView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let documentID: UUID
    let page: ScanPage
    let onDone: (Quad) -> Void

    @State private var image: UIImage?
    @State private var quad: Quad = .full
    @State private var dragStart: Quad?
    @State private var activeHandle: Handle?
    @State private var detecting = false
    @State private var notFound = false

    private let handleSize: CGFloat = 28
    private let loupeSize: CGFloat = 120
    private let loupeZoom: CGFloat = 2.5

    enum Handle: Equatable {
        case corner(Int)
        case edge(Int) // edge i runs from corner i to corner i+1
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let area = proxy.size
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let image {
                        let rect = fittedRect(image.size, in: area)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        overlay(in: rect)
                        handles(in: rect)
                        if let activeHandle {
                            loupe(image: image, rect: rect, area: area, handle: activeHandle)
                        }
                    } else {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .ignoresSafeArea(edges: .horizontal)
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(quad)
                        dismiss()
                    }
                    .disabled(!quad.isValid)
                    .accessibilityIdentifier("cropDoneButton")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        autoDetect()
                    } label: {
                        Label("Auto Detect", systemImage: "viewfinder")
                    }
                    .disabled(detecting || image == nil)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { quad = .full }
                    } label: {
                        Label("Full Page", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            .alert("No Document Found", isPresented: $notFound) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Drag the corners to the edges of the paper.")
            }
        }
        .task {
            quad = page.quad
            let url = store.originalURL(documentID, page.id)
            image = await Task.detached(priority: .userInitiated) {
                DocumentStore.loadImage(at: url, maxPixelSize: 2048)
            }.value
        }
    }

    // MARK: - Drawing

    private func overlay(in rect: CGRect) -> some View {
        let pts = quad.points.map { point(in: rect, $0) }
        return ZStack {
            // Dim everything outside the crop.
            Path { p in
                p.addRect(rect)
                p.addLines(pts)
                p.closeSubpath()
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Path { p in
                p.addLines(pts)
                p.closeSubpath()
            }
            .stroke(quad.isValid ? Color.accentColor : Color.red, lineWidth: 2)
        }
        .allowsHitTesting(false)
    }

    private func handles(in rect: CGRect) -> some View {
        let pts = quad.points.map { point(in: rect, $0) }
        return ZStack {
            ForEach(0..<4, id: \.self) { i in
                let a = pts[i], b = pts[(i + 1) % 4]
                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 26, height: 8)
                    .rotationEffect(.radians(atan2(b.y - a.y, b.x - a.x)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    .gesture(drag(.edge(i), rect: rect))
            }
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                    .frame(width: handleSize, height: handleSize)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                    .position(pts[i])
                    .gesture(drag(.corner(i), rect: rect))
                    .accessibilityIdentifier("cropHandle\(i)")
            }
        }
    }

    private func loupe(image: UIImage, rect: CGRect, area: CGSize, handle: Handle) -> some View {
        let focus: CGPoint
        switch handle {
        case .corner(let i):
            focus = quad[i]
        case .edge(let i):
            let a = quad[i], b = quad[(i + 1) % 4]
            focus = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let zoomed = CGSize(width: rect.width * loupeZoom, height: rect.height * loupeZoom)
        // Sit in the top corner away from the finger.
        let onLeft = focus.x > 0.5
        let center = CGPoint(x: onLeft ? loupeSize / 2 + 16 : area.width - loupeSize / 2 - 16, y: loupeSize / 2 + 16)
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: zoomed.width, height: zoomed.height)
                .offset(x: loupeSize / 2 - focus.x * zoomed.width, y: loupeSize / 2 - focus.y * zoomed.height)
                .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            Image(systemName: "plus")
                .font(.title3.weight(.light))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: loupeSize, height: loupeSize)
        .background(Color.black)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
        .shadow(radius: 6)
        .position(center)
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func drag(_ handle: Handle, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = quad
                    activeHandle = handle
                }
                guard let start = dragStart, rect.width > 0, rect.height > 0 else { return }
                let dx = value.translation.width / rect.width
                let dy = value.translation.height / rect.height
                var next = start
                switch handle {
                case .corner(let i):
                    next[i] = clamp(CGPoint(x: start[i].x + dx, y: start[i].y + dy))
                case .edge(let i):
                    let j = (i + 1) % 4
                    next[i] = clamp(CGPoint(x: start[i].x + dx, y: start[i].y + dy))
                    next[j] = clamp(CGPoint(x: start[j].x + dx, y: start[j].y + dy))
                }
                quad = next
            }
            .onEnded { _ in
                dragStart = nil
                activeHandle = nil
            }
    }

    private func autoDetect() {
        guard let cg = image?.cgImage else { return }
        detecting = true
        Task {
            let found = await DocumentDetector.detect(in: cg)
            detecting = false
            if let found {
                withAnimation(.snappy) { quad = found }
            } else {
                notFound = true
            }
        }
    }

    // MARK: - Geometry

    private func fittedRect(_ size: CGSize, in area: CGSize) -> CGRect {
        let inset: CGFloat = 24
        let avail = CGSize(width: max(1, area.width - inset * 2), height: max(1, area.height - inset * 2))
        let scale = min(avail.width / max(size.width, 1), avail.height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    private func point(in rect: CGRect, _ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }
}
