//
//  ContentView.swift
//  Privacy Blinds
//
//  Test harness for the PrivacyBlinds package. Mock "secret" content sits under the
//  `.privacyBlinds` overlay; a clean monochrome panel (on top, never covered) lets you pick the
//  cover (black / color / image from the library) and shows whether the lens is currently
//  revealed or covered as you roll the device.
//

import SwiftUI
import PhotosUI
import UIKit
import PrivacyBlinds

enum DemoCover: String, CaseIterable, Identifiable {
    case black = "Black"
    case color = "Color"
    case image = "Image"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var selectedCover: DemoCover = .black
    @State private var lensClosed = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImage: Image?
    @State private var maskOn = false
    @State private var eyeTrackingOn = false

    /// Resolve the segmented selection into the package's `PrivacyCover`. If "Image" is selected
    /// but nothing has been picked yet, fall back to black.
    private var currentCover: PrivacyCover {
        switch selectedCover {
        case .black: return .black
        case .color: return .color(Color(white: 0.5))
        case .image: return pickedImage.map { PrivacyCover.image($0) } ?? .black
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // --- Protected content + the privacy lens overlay --------------------------------
            SecretContent()
                .privacyBlinds(
                    cover: currentCover,
                    maskFillRatio: maskOn ? 0.4 : 0,
                    maskCellSize: 3,
                    eyeTracking: eyeTrackingOn,
                    onStateChange: { closed in lensClosed = closed }
                )
                .ignoresSafeArea()

            // --- Control panel (sits above the lens, stays interactive) ----------------------
            controlPanel
                .padding()
        }
        .tint(.primary)
        .preferredColorScheme(.light)
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    pickedImage = Image(uiImage: uiImage)
                    selectedCover = .image
                }
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: lensClosed ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22, height: 22) // fixed box so eye/eye.slash don't change row height
                Text(lensClosed ? "Covered" : "Revealed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose Image", systemImage: "photo")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(.black)

            Picker("Cover", selection: $selectedCover) {
                ForEach(DemoCover.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Privacy mask", isOn: $maskOn)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.black)

            Toggle("Eye tracking", isOn: $eyeTrackingOn)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.black)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)
                .stroke(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
    }
}

/// Mock secret content — text-heavy so reveal/cover reads clearly. Clean B&W: white ground,
/// black headings, hairline dividers between entries (no filled boxes).
struct SecretContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Private Notes")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.top, 72)
                    .padding(.bottom, 8)

                ForEach(0..<12) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Entry \(i + 1)")
                            .font(.headline)
                            .foregroundStyle(.black)
                        Text("The quick brown fox jumps over the lazy dog. "
                             + "Sensitive details you only want visible while reading.")
                            .font(.subheadline)
                            .foregroundStyle(.black.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)

                    if i < 11 { Divider().overlay(.black.opacity(0.08)) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 220) // keep last rows clear of the control panel
        }
        .background(Color.white)
    }
}

#Preview {
    ContentView()
}
